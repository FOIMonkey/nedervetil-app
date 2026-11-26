require 'spec_helper'

RSpec.describe 'Disclosures views by role' do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'
  include_context 'with production error pages'

  let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:other) { FactoryBot.create(:user) }
  let(:info_request) do
    FactoryBot.create(:info_request, user: owner, title: 'Pothole repairs 2024')
  end
  let(:letter) do
    AttachmentFixtures.pdf(
      pages: [
        {
          texts: [
            { x: 72,
              y: 760,
              text: 'Freedom of Information request: pothole repairs',
              size: 12 },
            { x: 72, y: 700, text: 'Repairs     Ward     Cost', size: 12 }
          ]
        }
      ]
    )
  end
  let(:message) do
    AttachmentFixtures.deliver(info_request,
                               [['response.pdf', 'application/pdf', letter]])
  end
  let(:attachment) do
    message.get_attachments_for_display.
      find { |a| a.filename == 'response.pdf' }
  end

  def as(user)
    user ? sign_in(user) : reset!
  end

  def page(path)
    get path
    if response.status == 307
      expect(response.location).to include('/admin/documents/')
      follow_redirect!
    end
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  def draft
    Disclosures::Creation.new(user: owner,
                              attachment: attachment,
                              kind: 'released_records').create!
  end

  def published
    document = draft
    publish(document, by: admin)
    document.reload
  end

  def request_path
    "/request/#{info_request.url_title}"
  end

  def document_path(document)
    "/documents/#{document.public_id}"
  end

  describe 'a published document' do
    it 'is public, and its request is not' do
      document = published
      as(nil)
      get request_path
      expect(response).to have_http_status(:not_found)
      get document_path(document)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(document.title)
      expect(response.body).not_to include(info_request.title)
    end

    it 'never links a document to its request' do
      document = published
      [nil, owner, admin].each do |user|
        as(user)
        doc = page(document_path(document))
        expect(doc.css('a').map { |a| a['href'] }).not_to include(request_path)
        expect(doc.text).not_to include(info_request.title)
      end
    end
  end

  it 'lists no documents in the sidebar of a private request' do
    published
    info_request.update!(prominence: 'requester_only')
    as(owner)
    expect(page(request_path).at_css('.sidebar__request-documents')).to be_nil
  end

  it 'names the document made from a thread attachment for the requester and admins only' do
    document = draft
    [owner, admin].each do |user|
      as(user)
      doc = page(request_path)
      line = doc.at_css("#attachment-#{attachment.id} .attachment__document")
      expect(line.text.squish).to eq("Draft Open it: #{document.title}")
      expected = if user == owner
                   "/request/#{info_request.url_title}/publish/" \
                   "#{document.incoming_message_id}/check"
                 else
                   "#{document_path(document)}/manage"
                 end
      expect(line.at_css('a')['href']).to eq(expected)
    end
    [nil, other].each do |user|
      as(user)
      get request_path
      expect(response).to have_http_status(:not_found)
      expect(Nokogiri::HTML(response.body).at_css('.attachment__document')).
        to be_nil
    end
  end

  it 'shows a draft’s state once, in the panel, and its type as a fact, for the requester and admins' do
    document = draft
    [owner, admin].each do |user|
      as(user)
      manage = page("#{document_path(document)}/manage")
      expect(manage.css('.document-state').map { |el| el.text.strip }).
        to eq(['Draft'])
      expect(manage.at_css('.document__kind')).to be_nil
      expect(manage.at_css('.document__facts').text).
        to include('Type', document.kind_label)
    end
  end

  it 'shows no state beside the type of a public document' do
    document = published
    as(owner)
    expect(page(document_path(document)).
             at_css('.document__kind .document-state')).to be_nil
  end

  it 'keeps the status line of a draft neutral' do
    document = draft
    as(owner)
    body = page("#{document_path(document)}/manage").at_css('.document-manage').
      text.squish
    expect(body).to include('Not published yet.')
    expect(body).not_to include('Waiting for an admin', 'An admin')
  end

  describe 'the request panel’s Make buttons' do
    include_context 'with the publish flow off'

    let!(:reply) do
      AttachmentFixtures.deliver(
        info_request,
        [['runs.txt', 'text/plain', "Gritting runs by ward\nNorth: 12\n"]]
      )
    end
    let(:runs) do
      reply.get_attachments_for_display.
        find { |part| part.filename == 'runs.txt' }
    end

    def suggest(suggestion)
      suggest_documents
      Disclosures::Suggestion.find_by!(foi_attachment_id: runs.id).
        update_columns(suggestion: suggestion)
    end

    def row
      as(owner)
      page(request_path).css('.documents-panel__file').find do |li|
        li.at_css('.documents-panel__name').text.strip == 'runs.txt'
      end
    end

    def buttons(row)
      row.css('button[name="kind"]').
        map { |button| [button['value'], button['class'].split - ['button']] }
    end

    it 'puts the decision letter first and highlights only the suggested kind' do
      suggest('released_records')
      expect(row.at_css('.documents-panel__name a')['href']).
        to eq("#attachment-#{runs.id}")
      expect(buttons(row)).
        to eq([['decision_letter', ['documents-panel__plain']],
               ['released_records', ['documents-panel__primary']]])
      suggest('decision_letter')
      expect(buttons(row)).
        to eq([['decision_letter', ['documents-panel__primary']],
               ['released_records', ['documents-panel__plain']]])
    end

    it 'highlights neither for a file to have a look at, and sets it aside in a routine reply' do
      suggest('look')
      found = row
      expect(buttons(found).map(&:last)).
        to eq([['documents-panel__plain'], ['documents-panel__plain']])
      expect(found.ancestors('.documents-todo__fold')).to be_empty

      if defined?(IncomingAttention::Labels)
        allow(IncomingAttention::Labels).to receive(:routine?).and_call_original
        allow(IncomingAttention::Labels).
          to receive(:routine?).with(reply).and_return(true)
        found = row
        expect(found.ancestors('.documents-todo__fold').first.
               at_css('summary').text).
          to start_with('Set aside')
      end
    end
  end

  it 'names a spreadsheet’s sheets as their tabs do, not by their file names' do
    workbook = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' \
               '<workbook xmlns="http://schemas.openxmlformats.org/' \
               'spreadsheetml/2006/main" ' \
               'xmlns:r="http://schemas.openxmlformats.org/' \
               'officeDocument/2006/relationships"><sheets>' \
               '<sheet name="Fleet" sheetId="1" r:id="rId2"/>' \
               '<sheet name="Notes" sheetId="2" r:id="rId1"/>' \
               '</sheets></workbook>'
    xlsx = AttachmentFixtures.ooxml(
      '[Content_Types].xml' => AttachmentFixtures.content_types(
        '/xl/workbook.xml' => 'application/vnd.openxmlformats-' \
                              'officedocument.spreadsheetml.sheet.main+xml'
      ),
      '_rels/.rels' => AttachmentFixtures.rels(
        'officeDocument' => 'xl/workbook.xml'
      ),
      'xl/workbook.xml' => workbook,
      'xl/_rels/workbook.xml.rels' => AttachmentFixtures.rels(
        'worksheet' => %w[worksheets/sheet1.xml /xl/worksheets/fleet.xml]
      ),
      'xl/worksheets/sheet1.xml' => AttachmentFixtures.sheet(
        [['Note'], ['Hidden note']], hidden_rows: [2]
      ),
      'xl/worksheets/fleet.xml' => AttachmentFixtures.sheet(
        [['Van'], ['Car'], ['Bus']], hidden_rows: [2, 3]
      )
    )
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'fleet.xlsx')
      File.binwrite(path, xlsx)
      findings = AttachmentManagement::OfficeInspector.findings(path)
      expect(findings).to include('Fleet: 2 hidden rows', 'Notes: 1 hidden row')
      expect(findings.join).not_to include('sheet1', 'fleet:')
    end
  end
end
