require 'spec_helper'

RSpec.describe Disclosures::Ocr do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'

  let(:secret) { 'Visible council records' }

  before do
    skip 'OCR tools missing' unless ocr_tools?
  end

  around do |example|
    Dir.mktmpdir('ocr-upright') do |dir|
      @dir = dir
      example.run
    end
  end

  def letter(text)
    page = AttachmentFixtures.letter_page(secret: text)
    ['We write in response to your request for information about',
     'the gritting of roads in the north of the county last winter.',
     'The council holds the records you asked for and they are',
     'enclosed with this letter in full.'].each_with_index do |line, index|
      page[:texts] << { x: 72, y: 540 - (index * 24), text: line, size: 12 }
    end
    page
  end

  def scan(degrees = 0, text: secret, page: letter(text))
    Dir.mktmpdir('ocr-upright-scan') do |dir|
      pdf = File.join(dir, 'page.pdf')
      File.binwrite(pdf, AttachmentFixtures.pdf(pages: [page]))
      png = AttachmentFixtures.render_pages(pdf, dir, dpi: 150).first
      scan = File.join(dir, 'scan.pdf')
      AttachmentFixtures.magick(png, '-background', 'white',
                                '-rotate', degrees.to_s, '+repage',
                                '-density', '150', scan)
      File.binread(scan)
    end
  end

  def path_of(pdf)
    File.join(@dir, 'scan.pdf').tap { |path| File.binwrite(path, pdf) }
  end

  def read(pdf)
    described_class.pdf_page(path_of(pdf), 1, @dir, job: nil)
  end

  def as_it_lies(pdf)
    Dir.mktmpdir('ocr-as-it-lies') do |dir|
      system('pdftoppm', '-f', '1', '-l', '1', '-scale-to',
             described_class::LONG_SIDE.to_s, '-gray', '-png', '-singlefile',
             path_of(pdf), File.join(dir, 'page'), exception: true)
      out, = Open3.capture2({ 'OMP_THREAD_LIMIT' => '1' }, 'tesseract',
                            File.join(dir, 'page.png'), '-', err: File::NULL)
      out.force_encoding('UTF-8')
    end
  end

  it 'reads an upright page exactly as Tesseract gives it' do
    pdf = scan
    expect(read(pdf)).to eq(as_it_lies(pdf))
    expect(read(pdf)).to include(secret)
  end

  it 'reads a page that lies on its side or upside down' do
    [90, 180, 270].each do |degrees|
      expect(read(scan(degrees))).to include(secret)
    end
  end

  it 'reads an upside-down page, which read as nothing before' do
    pdf = scan(180)
    expect(as_it_lies(pdf)).not_to include('council')
    expect(read(pdf)).to include(secret)
  end

  it 'reads a tilted page, which lost its words before' do
    pdf = scan(8)
    expect(as_it_lies(pdf)).not_to include(secret)
    expect(read(pdf)).to include(secret)
  end

  it 'keeps the reading of the page as it came when a confident turn was wrong' do
    allow(described_class).to receive(:quarter_turn).and_return([180, true])
    expect(read(scan)).to include(secret)
  end

  it 'tries the other ways up when the orientation check is unsure and the reading is weak' do
    allow(described_class).to receive(:quarter_turn).and_return([0, false])
    expect(read(scan(180))).to include(secret)
  end

  describe 'a page of a few words, which proves nothing about which way up it is' do
    let(:sparse) do
      { texts: [{ x: 72, y: 700, text: 'Annex B', size: 24 }] }
    end
    let(:junk) { described_class::Reading.new('lI .; ,l |I', [20, 30, 25]) }
    let(:few) do
      described_class::Reading.new('Five good words read sideways',
                                   [95, 95, 95, 95, 95])
    end

    def turned_readings_give(reading)
      allow(described_class).to receive(:reading).
        and_wrap_original do |original, png, degrees, job|
          degrees.zero? ? original.call(png, degrees, job) : reading
        end
    end

    it 'is read as it lies when the orientation check is unsure' do
      allow(described_class).to receive(:quarter_turn).and_return([0, false])
      pdf = scan(page: sparse)
      expect(read(pdf)).to eq(as_it_lies(pdf))
      expect(read(pdf)).to include('Annex B')
    end

    it 'is read as it lies when a confident turn reads only noise' do
      allow(described_class).to receive(:quarter_turn).and_return([180, true])
      turned_readings_give(junk)
      pdf = scan(page: { texts: [] })
      expect(read(pdf)).to eq(as_it_lies(pdf))
    end

    it 'is read as it lies when a guessed way up reads well but too little to prove itself' do
      allow(described_class).to receive(:quarter_turn).and_return([0, false])
      turned_readings_give(few)
      pdf = scan(page: sparse)
      expect(read(pdf)).to eq(as_it_lies(pdf))
    end

    it 'does not replace a fuller page: a sound turned reading with fewer words loses to the page as it lies' do
      allow(described_class).to receive(:quarter_turn).and_return([180, true])
      turned_readings_give(few)
      pdf = scan
      expect(read(pdf)).to eq(as_it_lies(pdf))
    end

    it 'is read turned when the orientation check is confident and the turned reading is sound' do
      allow(described_class).to receive(:quarter_turn).and_return([180, true])
      expect(read(scan(180, page: sparse))).to include('Annex B')
    end

    it 'stays as it lies, upside down, when the orientation check cannot tell: as before' do
      pdf = scan(180, page: sparse)
      expect(read(pdf)).to eq(as_it_lies(pdf))
    end
  end

  it 'reads a page with no words once: there is nothing to turn' do
    allow(described_class).to receive(:quarter_turn).and_return([0, false])
    allow(described_class).to receive(:tilt_after).and_return(0)
    expect(described_class).to receive(:reading).once.and_call_original
    expect(read(scan(page: { texts: [] })).to_s.strip).to eq('')
  end

  it 'tries the other ways up for a page of a few words the check is ' \
     'unsure of' do
    allow(described_class).to receive(:quarter_turn).and_return([0, false])
    allow(described_class).to receive(:tilt_after).and_return(0)
    expect(described_class).to receive(:reading).exactly(4).times.
      and_call_original
    read(scan(page: { texts: [{ x: 72, y: 700, text: 'Annex B', size: 24 }] }))
  end

  it 'reads a page of a few words once when the check is sure it is upright' do
    allow(described_class).to receive(:quarter_turn).and_return([0, true])
    allow(described_class).to receive(:tilt_after).and_return(0)
    expect(described_class).to receive(:reading).once.and_call_original
    read(scan(page: { texts: [{ x: 72, y: 700, text: 'Annex B', size: 24 }] }))
  end

  it 'gives a blank page what Tesseract gives it, and leaves no files behind' do
    blank = AttachmentFixtures.pdf(pages: [{ texts: [] }])
    expect(read(blank).to_s.strip).to eq('')
    read(scan(90))
    expect(Dir.children(@dir).sort).to eq(%w[ocr-1.png scan.pdf])
  end

  it 'is nil when the page cannot be rendered' do
    expect(read('not a pdf')).to be_nil
  end

  it 'finds the requester\'s name on an upside-down scan before it is published' do
    owner = FactoryBot.create(:user, name: 'Rowan Thistlewood')
    request = FactoryBot.create(:info_request, user: owner)
    Disclosures.ocr = true
    document = delivered_document(
      request, 'scan.pdf', 'application/pdf',
      scan(180, text: 'Dear Rowan Thistlewood')
    )
    Disclosures::Renderer.new(document).run
    page = document.pages.first
    expect(page.text_source).to eq('ocr')
    expect(page.text).to include('Rowan Thistlewood')
    expect(Disclosures::Checks.personal(document).map(&:page)).
      to include(1)
  end
end
