require 'spec_helper'

RSpec.describe AttachmentManagement::Engines::Raster do
  let(:engine) { described_class.new(job: nil) }
  let(:dir) { Dir.mktmpdir('engine-spec') }
  after { FileUtils.rm_rf(dir) }

  def write(name, bytes)
    File.join(dir, name).tap { |path| File.binwrite(path, bytes) }
  end

  def redact_pdf(pdf, boxes)
    output = File.join(dir, 'out.pdf')
    report = engine.redact_pdf(write('in.pdf', pdf), boxes, output)
    [output, report]
  end

  def pages_of(pdf_path, name)
    FileUtils.mkdir_p(File.join(dir, name))
    AttachmentFixtures.render_pages(pdf_path, File.join(dir, name))
  end

  # Ink means some dark pixels but mostly page: text that is still there.
  def ink?(stats)
    stats[:min] < 0.5 && stats[:mean] > 0.6
  end

  def black?(stats)
    stats[:max] <= 0.05
  end

  describe 'a multi-page PDF' do
    let(:pdf) do
      AttachmentFixtures.pdf(
        pages: [
          AttachmentFixtures.letter_page(secret: 'Case officer: Jane Example',
                                         note: 'Annotation naming Jane'),
          AttachmentFixtures.letter_page(secret: 'Witness: John Sample',
                                         heading: 'Annex A'),
          AttachmentFixtures.letter_page(secret: 'Nothing to redact here',
                                         heading: 'Annex B')
        ],
        info: { Author: 'Jane Example', Title: 'Internal draft' }
      )
    end

    it 'paints the boxes into the pages and keeps everything else in place' do
      output, report = redact_pdf(
        pdf, { 1 => [AttachmentFixtures.letter_secret_box],
               2 => [AttachmentFixtures.letter_secret_box] }
      )
      pages = pages_of(output, 'out')

      expect(pages.size).to eq(3)
      expect(
        black?(AttachmentFixtures.region(pages[0],
                                         AttachmentFixtures.letter_secret_box))
      ).to be true
      expect(
        black?(AttachmentFixtures.region(pages[1],
                                         AttachmentFixtures.letter_secret_box))
      ).to be true
      expect(
        ink?(AttachmentFixtures.region(pages[2],
                                       AttachmentFixtures.letter_secret_box))
      ).to be true
      expect(
        ink?(AttachmentFixtures.region(pages[0], [0.10, 0.07, 0.70, 0.11]))
      ).to be true # heading
      expect(
        ink?(AttachmentFixtures.region(pages[0], [0.10, 0.84, 0.60, 0.87]))
      ).to be true # footer
      expect(report).to include(boxes: 2, boxes_verified: 2, pages: 3,
                                fonts: 0, text_characters: 0)
    end

    it 'leaves no text layer, fonts, annotations or metadata' do
      output, _report = redact_pdf(
        pdf, { 1 => [AttachmentFixtures.letter_secret_box] }
      )
      raw = File.binread(output)

      expect(AttachmentFixtures.pdf_text(output).strip).to be_empty
      expect(`pdffonts #{output}`.lines.drop(2)).to be_empty
      expect(`pdfimages -list #{output}`.lines.drop(2).map { |l| l.split[1] }).
        to eq(%w[0 1 2])
      expect(raw).not_to include('Jane', 'Annot', 'Internal draft')
      expect(`pdfinfo #{output}`).not_to match(/^(Author|Title):/)
    end

    it 'records how much text the source had, for the review screen' do
      _output, report = redact_pdf(
        pdf, { 1 => [AttachmentFixtures.letter_secret_box] }
      )
      expect(report[:source][:pages]).to eq(3)
      expect(report[:source][:text_characters]).to be > 50
    end
  end

  it 'handles a page with /Rotate 90 in the orientation a reader sees' do
    pdf = AttachmentFixtures.pdf(
      pages: [
        AttachmentFixtures.letter_page(secret: 'Rotated: badge number 4471',
                                       rotate: 90)
      ]
    )
    source = pages_of(write('rotated.pdf', pdf), 'source')
    expect(
      ink?(AttachmentFixtures.region(source[0],
                                     AttachmentFixtures.rotated_secret_box))
    ).to be true

    output, _report = redact_pdf(
      pdf, { 1 => [AttachmentFixtures.rotated_secret_box] }
    )
    page = pages_of(output, 'out').first
    width, height = AttachmentFixtures.
      magick('identify', '-format', '%w %h', page).split.map(&:to_i)

    expect(width).to be > height
    expect(
      black?(AttachmentFixtures.region(page,
                                       AttachmentFixtures.rotated_secret_box))
    ).to be true
    expect(
      ink?(AttachmentFixtures.region(page, [0.88, 0.07, 0.95, 0.60]))
    ).to be true # heading, now upright on the right
    expect(AttachmentFixtures.pdf_text(output).strip).to be_empty
  end

  it 'keeps only the crop box of a cropped page, so content outside it is gone' do
    page = AttachmentFixtures.letter_page(secret: 'Visible: contract value',
                                          crop_box: [36, 100, 559, 800])
    page[:texts] << { x: 72, y: 40,
                      text: 'OUTSIDECROP John Sample home address' }
    pdf = AttachmentFixtures.pdf(pages: [page])
    expect(AttachmentFixtures.pdf_text(write('cropped.pdf', pdf))).
      to include('OUTSIDECROP')

    output, _report = redact_pdf(pdf, {})
    size = `pdfinfo #{output}`[/Page size:\s+([\d.]+) x ([\d.]+)/, 0]
    width, height = size.scan(/[\d.]+/).map(&:to_f)

    expect(width).to be_within(1.5).of(523)
    expect(height).to be_within(1.5).of(700)
    expect(AttachmentFixtures.pdf_text(output).strip).to be_empty
    expect(File.binread(output)).not_to include('OUTSIDECROP')
  end

  it 'removes white text and text hidden under a drawn rectangle' do
    pdf = AttachmentFixtures.pdf(
      pages: [{ texts: [{ x: 72, y: 700, text: 'Summary', size: 18 },
                        { x: 72, y: 500, text: 'WHITETEXT personnel file',
                          colour: [1, 1, 1] },
                        { x: 72, y: 300, text: 'UNDERBOX date of birth' }],
                boxes: [{ x: 60, y: 290, w: 460, h: 30 }] }]
    )
    expect(AttachmentFixtures.pdf_text(write('hidden.pdf', pdf))).
      to include('WHITETEXT', 'UNDERBOX')

    output, _report = redact_pdf(pdf, {})

    expect(AttachmentFixtures.pdf_text(output).strip).to be_empty
    expect(File.binread(output)).not_to include('WHITETEXT', 'UNDERBOX')
  end

  it 'renders a poster-sized page at a lower resolution rather than a giant image' do
    pdf = AttachmentFixtures.pdf(
      pages: [{ size: [7200, 7200],
                texts: [{ x: 600, y: 3600, text: 'Poster', size: 400 }] }]
    )
    output, report = redact_pdf(pdf, { 1 => [[0.05, 0.40, 0.95, 0.60]] })
    width = `pdfimages -list #{output}`.lines.drop(2).first.split[3].to_i

    expect(width).to be_between(4000, described_class::MAX_SIDE)
    expect(report[:boxes_verified]).to eq(1)
  end

  it 'refuses more pages than it will process' do
    stub_const("#{described_class}::MAX_PAGES", 2)
    pdf = AttachmentFixtures.pdf(
      pages: Array.new(3) { AttachmentFixtures.letter_page(secret: 'x') }
    )
    expect { redact_pdf(pdf, {}) }.
      to raise_error(AttachmentManagement::Unsupported) { |e|
        expect(e.reason).to eq(:too_large)
      }
  end

  describe 'rebuilding a long PDF' do
    let(:runs) { [] }

    before do
      allow(AttachmentManagement::Command).
        to receive(:run).
        and_wrap_original do |original, program, *args, **options|
          runs << [program, *args]
          original.call(program, *args, **options)
        end
    end

    def ran(program)
      runs.select { |run| run.first == program }
    end

    it 'refuses more pages than it rebuilds before rendering any' do
      stub_const("#{described_class}::MAX_REBUILT_PAGES", 2)
      pdf = AttachmentFixtures.pdf(
        pages: Array.new(3) { AttachmentFixtures.letter_page(secret: 'x') }
      )
      expect { redact_pdf(pdf, {}) }.
        to raise_error(AttachmentManagement::Command::Failed,
                       '3 pages is too many to rebuild (the most is 2)')
      expect(ran('pdftoppm')).to be_empty
    end

    it 'stops once the pages built pass the output limit, before joining them' do
      allow(AttachmentManagement).to receive(:max_bytes).and_return(1)
      pdf = AttachmentFixtures.pdf(
        pages: Array.new(3) { AttachmentFixtures.letter_page(secret: 'x') }
      )
      expect { redact_pdf(pdf, {}) }.
        to raise_error(AttachmentManagement::Command::Failed,
                       /rebuilt PDF would be over .*\(1 of 3 pages\)/)
      expect(ran('pdftoppm').size).to eq(1)
      expect(ran('pdftk')).to be_empty
    end

    it 'keeps no page image once its page is built, and sizes pages from one pdfinfo' do
      pdf = AttachmentFixtures.pdf(
        pages: Array.new(3) do
          AttachmentFixtures.letter_page(secret: 'Case officer: Jane Example')
        end
      )
      images_at_join = nil
      allow(AttachmentManagement::Command).
        to receive(:run).
        and_wrap_original do |original, program, *args, **options|
          if program == 'pdftk'
            images_at_join = Dir[File.join(File.dirname(args.first),
                                           'page-*.png')]
          end
          runs << [program, *args]
          original.call(program, *args, **options)
        end

      _output, report = redact_pdf(
        pdf, { 1 => [AttachmentFixtures.letter_secret_box],
               3 => [AttachmentFixtures.letter_secret_box] }
      )

      expect(images_at_join).to eq([])
      expect(report).to include(pages: 3, boxes: 2, boxes_verified: 2)
      # pdf_info and page_sizes, for the input and the output; none per page.
      expect(ran('pdfinfo').size).to eq(4)
    end
  end

  it 'refuses a PDF that needs a password' do
    pdf = AttachmentFixtures.encrypted_pdf(
      AttachmentFixtures.pdf(
        pages: [AttachmentFixtures.letter_page(secret: 'Locked')]
      )
    )
    expect { redact_pdf(pdf, {}) }.
      to raise_error(AttachmentManagement::Unsupported) { |e|
        expect(e.reason).to eq(:encrypted)
      }
  end

  it 'refuses a file that is not a PDF' do
    expect { redact_pdf('%PDF-1.4 not really a PDF', {}) }.
      to raise_error(AttachmentManagement::Unsupported) { |e|
        expect(e.reason).to eq(:unreadable_pdf)
      }
  end

  it 'fails closed when the output check finds text left' do
    allow(engine).to receive(:text_characters).and_return(12)
    pdf = AttachmentFixtures.pdf(
      pages: [AttachmentFixtures.letter_page(secret: 'x')]
    )
    expect { redact_pdf(pdf, {}) }.
      to raise_error(AttachmentManagement::Command::Failed,
                     /12 characters of text left/)
  end

  describe 'images' do
    it 'paints boxes on a phone photo as it is displayed and drops its metadata' do
      photo = AttachmentFixtures.phone_photo(
        lines: [[40, 120, 'Notice to Jane Example'],
                [40, 300, 'Keep this line']]
      )
      input = write('photo.jpg', photo)
      expect(AttachmentFixtures.magick('identify', '-format',
                                       '%[orientation] %[EXIF:GPSLatitude]',
                                       input)).
        to start_with('RightTop 51/1')

      box = [0.03, 0.15, 0.97, 0.30] # the top line, once the photo is upright
      output = File.join(dir, 'out.jpg')
      report = engine.redact_image(input, 'jpeg', [box], output)

      expect(AttachmentFixtures.magick('identify', '-format',
                                       '%w %h %[EXIF:*]%c', output).strip).
        to eq('800 500')
      expect(black?(AttachmentFixtures.region(output, box))).to be true
      expect(
        ink?(AttachmentFixtures.region(output, [0.03, 0.50, 0.97, 0.65]))
      ).to be true
      expect(report[:metadata_removed]).
        to include('EXIF GPSLatitude', 'EXIF Orientation', 'comment')
      expect(report[:metadata_removed].join).not_to include('51/1')
    end

    it 'paints the boxes on every frame of an animated GIF' do
      frame = ->(text) do
        AttachmentFixtures.image(lines: [[20, 100, text]], width: 300,
                                 height: 200, format: 'gif')
      end
      first = write('a.gif', frame.call('frame one SECRET'))
      second = write('b.gif', frame.call('frame two SECRET'))
      input = File.join(dir, 'anim.gif')
      AttachmentFixtures.magick('-delay', '50', first, second, input)
      expect(engine.image_info(input, 'gif')[:frames]).to eq(2)

      box = [0.03, 0.30, 0.97, 0.62]
      output = File.join(dir, 'out.gif')
      report = engine.redact_image(input, 'gif', [box], output)

      expect(report).to include(frames: 2, boxes: 1, boxes_verified: 2)
      AttachmentFixtures.magick(output, '-coalesce',
                                File.join(dir, 'frame-%d.png'))
      expect(
        black?(AttachmentFixtures.region(File.join(dir, 'frame-0.png'), box))
      ).to be true
      expect(
        black?(AttachmentFixtures.region(File.join(dir, 'frame-1.png'), box))
      ).to be true
    end

    it 'refuses a multi-page TIFF' do
      input = File.join(dir, 'pages.tiff')
      File.binwrite(File.join(dir, 'a.png'),
                    AttachmentFixtures.image(lines: [[20, 100, 'one']]))
      AttachmentFixtures.magick(File.join(dir, 'a.png'),
                                File.join(dir, 'a.png'), input)
      expect do
        engine.redact_image(input, 'tiff', [[0.1, 0.1, 0.5, 0.5]],
                            File.join(dir, 'o.tiff'))
      end.to raise_error(AttachmentManagement::Unsupported) { |e|
        expect(e.reason).to eq(:multi_page_image)
      }
    end
  end

  describe 'Office files' do
    it 'converts a Word document to PDF with LibreOffice, keeping its text' do
      input = write('letter.docx',
                    AttachmentFixtures.docx(
                      paragraphs: ['Dear Spike Owner,',
                                   'This letter names DOCXSECRET Person.']
                    ))
      output = File.join(dir, 'letter.pdf')
      report = engine.convert_to_pdf(input, 'docx', output)

      expect(report[:pages]).to eq(1)
      expect(AttachmentFixtures.pdf_text(output)).to include('DOCXSECRET')
    end

    it 'leaves a hidden sheet and a hidden row out of a spreadsheet converted to PDF' do
      input = write('incidents.xlsx', AttachmentFixtures.xlsx)
      output = File.join(dir, 'incidents.pdf')
      engine.convert_to_pdf(input, 'xlsx', output)
      text = AttachmentFixtures.pdf_text(output)

      expect(text).to include('Incidents')
      expect(text).not_to include('HIDDENSHEET', 'HIDDENROW')
    end

    it 'lists what an Office file carries that the page does not show' do
      expect(AttachmentManagement::OfficeInspector.
               findings(write('x.xlsx', AttachmentFixtures.xlsx))).
        to include('Hidden sheet: Staff', 'Summary: 1 hidden row',
                   'Author in document properties: Jane Example')
      expect(AttachmentManagement::OfficeInspector.
               findings(write('d.docx',
                              AttachmentFixtures.docx(paragraphs: ['Hi'])))).
        to include('2 tracked changes', '1 runs of hidden text', '1 comment')
      expect(AttachmentManagement::OfficeInspector.
               findings(write('n.docx', 'not a zip'))).
        to eq(['Not an Office Open XML file, so its hidden content could ' \
               'not be listed.'])
    end
  end
end
