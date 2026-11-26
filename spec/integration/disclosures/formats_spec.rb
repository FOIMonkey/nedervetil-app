require 'spec_helper'

RSpec.describe 'Disclosures formats' do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'

  let(:kept) do
    { 'letter.pdf' => 'application/pdf',
      'figures.xlsx' => 'application/vnd.openxmlformats-officedocument.' \
                        'spreadsheetml.sheet',
      'figures.xlsm' => 'application/vnd.ms-excel.sheet.macroEnabled.12',
      'budget.xls' => 'application/vnd.ms-excel',
      'briefing.docx' => 'application/vnd.openxmlformats-officedocument.' \
                         'wordprocessingml.document',
      'minutes.doc' => 'application/msword',
      'slides.pptx' => 'application/vnd.openxmlformats-officedocument.' \
                       'presentationml.presentation',
      'wards.csv' => 'text/csv',
      'notes.txt' => 'text/plain',
      'page.html' => 'text/html' }
  end
  # Declared types core keeps as they are when a reply arrives.
  let(:left) do
    { 'slides.ppt' => 'application/vnd.ms-powerpoint',
      'notes.odt' => 'application/vnd.oasis.opendocument.text',
      'figures.ods' => 'application/vnd.oasis.opendocument.spreadsheet',
      'slides.odp' => 'application/vnd.oasis.opendocument.presentation',
      'letter.rtf' => 'application/rtf',
      'photo.jpg' => 'image/jpeg',
      'scan.png' => 'image/png',
      'records.zip' => 'application/zip' }
  end

  let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:info_request) do
    FactoryBot.create(:info_request, user: owner, title: 'Fleet vehicles 2025')
  end

  def part(message, name)
    message.get_attachments_for_display.
      find { |attachment| attachment.filename == name }
  end

  it 'keeps the owner’s formats and leaves everything else out' do
    kept.each do |name, type|
      expect(Disclosures::Formats.supported?(type, name)).to be(true), name
    end
    others = left.merge('memo.rtf' => 'text/rtf',
                        'scan.tiff' => 'image/tiff',
                        'invite.ics' => 'text/calendar',
                        'data.bin' => 'application/octet-stream')
    others.each do |name, type|
      expect(Disclosures::Formats.supported?(type, name)).to be(false), name
    end
    expect(Disclosures::Formats.supported?('application/octet-stream',
                                           'figures.xlsx')).to be(true)
  end

  it 'refuses to make a document from a file in any other format' do
    files = kept.merge(left).
      map { |name, type| [name, type, "Synthetic #{name}\n" * 20] }
    message = AttachmentFixtures.deliver(info_request, files)
    kept.each_key do |name|
      read_by_analyzer(part(message, name))
      expect {
        Disclosures::Creation.new(user: owner,
                                  attachment: part(message, name),
                                  kind: 'released_records').create!
      }.not_to raise_error
    end
    left.each_key do |name|
      expect {
        Disclosures::Creation.new(user: owner,
                                  attachment: part(message, name),
                                  kind: 'released_records').create!
      }.to raise_error(Disclosures::Error::Refused,
                       Disclosures::Formats::REFUSED)
    end
    expect(Disclosures::Document.where(info_request_id: info_request.id).count).
      to eq(kept.size)
  end

  # An OLE2 compound file, as older Office (.doc, .xls) writes.
  let(:ole) do
    "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1".b + ("\0".b * 504) +
      'Synthetic minutes'.b
  end

  it 'checks the bytes as well as the name and type' do
    docx = kept['briefing.docx']
    xlsx = kept['figures.xlsx']
    docx_bytes = DocumentFixtures.docx(paragraphs: ['Briefing'])
    xlsx_bytes = DocumentFixtures.zip('xl/workbook.xml' => '<workbook/>')
    pdf = AttachmentFixtures.pdf(
      pages: [{ texts: [{ x: 72, y: 760, text: 'Fleet vehicles', size: 14 }] }]
    )
    expect(Disclosures::Formats.for('application/vnd.ms-word',
                                    'minutes.doc', ole)).to eq('document')
    expect(Disclosures::Formats.for('application/msword',
                                    'minutes.doc', ole)).to eq('document')
    expect(Disclosures::Formats.for('application/vnd.ms-excel',
                                    'budget.xls', ole)).to eq('spreadsheet')
    expect(Disclosures::Formats.for('application/vnd.ms-word',
                                    'minutes.doc', docx_bytes)).to eq('other')
    expect(Disclosures::Formats.for('application/vnd.ms-excel',
                                    'budget.xls', xlsx_bytes)).to eq('other')
    expect(Disclosures::Formats.for(xlsx, 'budget.xlsx', ole)).to eq('other')
    expect(Disclosures::Formats.supported?(docx, 'minutes.docx', ole)).
      to be(false)
    expect(Disclosures::Formats.supported?('text/html', 'slides.ppt', ole)).
      to be(false)
    expect(
      Disclosures::Formats.supported?('text/html', 'budget.xls',
                                      '<table><tr><td>1</td></tr></table>')
    ).to be(false)
    expect(Disclosures::Formats.supported?(docx, 'briefing.docx', docx_bytes)).
      to be(true)
    expect(
      Disclosures::Formats.supported?(
        xlsx,
        'figures.xlsx',
        DocumentFixtures.zip('word/document.xml' => '<w:document/>')
      )
    ).to be(false)
    expect(Disclosures::Formats.supported?('application/pdf',
                                           'letter.pdf',
                                           "\xEF\xBB\xBF \r\n".b + pdf)).
      to be(true)
    expect(Disclosures::Formats.supported?('application/pdf',
                                           'letter.pdf',
                                           "<html>#{pdf}</html>")).to be(false)
    expect(Disclosures::Formats.supported?('text/csv',
                                           'wards.csv',
                                           "Ward,Note\nCaf\xE9,\x80 5\n".b)).
      to be(true)
    expect(Disclosures::Formats.supported?('text/plain',
                                           'notes.txt',
                                           "Notes \x81\n".b)).to be(false)
    expect(
      Disclosures::Formats.supported?('text/plain', 'notes.txt', "Notes\0\n")
    ).to be(false)
    expect(Disclosures::Formats.supported?('text/plain', 'notes.txt', nil)).
      to be(true)
  end

  it 'leaves an older Office file named .docx in the thread' do
    message = AttachmentFixtures.deliver(
      info_request, [['minutes.docx', kept['briefing.docx'], ole]]
    )
    # Word files are scanned for embedded spreadsheets before the requester
    # can use them (Disclosures::SpreadsheetHold.waiting?).
    read_by_analyzer(part(message, 'minutes.docx'))
    Disclosures::Suggester.new(message).run
    expect(Disclosures::Suggestion.
             find_by(foi_attachment_id: part(message, 'minutes.docx').id)).
      to have_attributes(suggestion: 'none', rule: 'format')

    document = Disclosures::Creation.new(
      user: owner,
      attachment: part(message, 'minutes.docx'),
      kind: 'released_records'
    ).create!
    Disclosures::Renderer.new(document).run
    expect(document.reload).to have_attributes(
      format: 'other',
      render_notes: hash_including('no_preview' => 'unknown')
    )
  end

  it 'lists a file that stays in the thread on the request page with no suggestion or button' do
    message = AttachmentFixtures.deliver(
      info_request,
      [['records.zip', 'application/zip',
        DocumentFixtures.zip('a.csv' => "a,b\n1,2\n")],
       ['wards.csv', 'text/csv', "Ward,Repairs\nNorth,12\n"]]
    )
    Disclosures::Suggester.new(message).run
    sign_in(owner)
    document_request :get, "/request/#{info_request.url_title}"
    page = Nokogiri::HTML(response.body)
    expect(
      page.css('a').find { |link| link.text == 'Share documents' }['href']
    ).to eq("/request/#{info_request.url_title}/publish/#{message.id}")
    sign_in(owner)
    document_request :get,
                     "/request/#{info_request.url_title}/publish/#{message.id}"
    page = Nokogiri::HTML(response.body)
    expect(
      page.at_css(%(input[name="files[#{part(message, 'records.zip').id}]"]))
    ).to be_nil
    expect(
      page.at_css(%(input[name="files[#{part(message, 'wards.csv').id}]"]))
    ).to be_present
  end

  it 'doesn’t flag a page whose only masked text is an address core had already covered' do
    pdf = AttachmentFixtures.pdf(
      pages: [
        { texts: [{ x: 72,
                    y: 700,
                    text: 'Contact officer.name@synthetic-authority.test today',
                    size: 12 }] }
      ]
    )
    message = AttachmentFixtures.deliver(
      info_request, [['letter.pdf', 'application/pdf', pdf]]
    )
    document = Disclosures::Creation.new(
      user: owner,
      attachment: part(message, 'letter.pdf'),
      kind: 'decision_letter'
    ).create!
    publish(document, by: admin)
    document.reload
    expect(document.pages.first.text).to include('Contact [redacted] today')
    expect(document.pages.first.text).not_to include('synthetic-authority')
    expect(Array(document.render_notes['masked_pages'])).to be_empty
  end
end
