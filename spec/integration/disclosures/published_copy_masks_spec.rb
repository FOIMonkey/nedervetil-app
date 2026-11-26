require 'spec_helper'

RSpec.describe 'Masks on a published copy' do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'

  let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:info_request) do
    FactoryBot.create(:info_request, user: owner, title: 'Road contracts')
  end
  let(:email) { 'officer@synthetic-authority.test' }
  let(:letter) do
    AttachmentFixtures.pdf(
      pages: [AttachmentFixtures.letter_page(secret: "Write to #{email}")],
      info: { 'Author' => email }
    )
  end

  def text_of(bytes)
    Dir.mktmpdir do |dir|
      File.binwrite(File.join(dir, 'c.pdf'), bytes)
      AttachmentFixtures.pdf_text(File.join(dir, 'c.pdf'))
    end
  end

  # Every object readable, the Info dictionary included.
  def decoded(pdf)
    PDFRedactor.qpdf(pdf, '--qdf', '--object-streams=disable').first
  end

  def delivered(name = 'response.pdf', type = 'application/pdf', body = letter)
    message = AttachmentFixtures.deliver(info_request, [[name, type, body]])
    attachment = file_in(message, name)
    read_by_analyzer(attachment)
    attachment.mask
    FoiAttachment.find(attachment.id)
  end

  def published(document)
    publish(document, by: admin)
    reset!
    get "/documents/#{document.public_id}", params: { view: 'text' }
    text = Nokogiri::HTML(response.body).at_css('#document-pages').text
    get "/documents/#{document.public_id}/download"
    [text.squish, response.body]
  end

  def document_from_reply(text)
    reply = AttachmentFixtures.deliver(info_request, [], text: text)
    Disclosures::Creation.new(
      user: owner, attachment: reply.get_main_body_text_part,
      kind: 'decision_letter', email_text: true
    ).create!
  end

  it 'masks a mobile number that follows an address and a full stop' do
    document = document_from_reply(
      "Email: jane.doe@council.gov.uk.Mobile: 07700 900123\n\nJane Example\n"
    )

    text, file = published(document)

    expect(text).to include('Email: [email address].[mobile number]')
    expect(file).to include('Email: [email address].[mobile number]')
    expect(text + file).not_to include('07700')
  end

  describe 'an address at a domain such as gov.wales or llyw.cymru' do
    let(:contacts) { 'Ask jane.doe@gov.wales or foi@llyw.cymru' }

    it 'is masked in a reply’s text published as a document' do
      document =
        document_from_reply("#{contacts} about this.\n\nJane Example\n")

      text, file = published(document)

      expect(text).
        to include('Ask [email address] or [email address] about this.')
      expect(file).
        to include('Ask [email address] or [email address] about this.')
    end

    it 'is masked in a PDF published as a document' do
      pages = [AttachmentFixtures.letter_page(secret: contacts)]
      attachment = delivered('response.pdf', 'application/pdf',
                             AttachmentFixtures.pdf(pages: pages))
      document = document_from_attachment(attachment, by: owner)

      text, file = published(document)

      expect(text).to include('Ask [redacted] or [redacted]')
      expect(text_of(file)).not_to include('gov.wales', 'llyw.cymru')
    end
  end

  it 'masks a PDF declared as application/x-pdf' do
    attachment = delivered('response.pdf', 'application/x-pdf')
    expect(attachment.content_type).to eq('application/x-pdf')

    document = document_from_attachment(attachment, by: owner)
    publish(document, by: admin)
    copy = document.foi_attachment.reload.file.download

    expect(decoded(copy)).not_to include(email)
    expect(text_of(copy)).not_to include('@')
  end

  it 'masks a text file with a censor rule that has accents' do
    FactoryBot.create(:info_request_censor_rule,
                      censorable: info_request, text: 'Siân',
                      replacement: '[name]')
    attachment = delivered('notes.txt', 'text/plain',
                           "Ask Siân Jones, at #{email}, café hours.\n")

    document = document_from_attachment(attachment, by: owner)
    publish(document, by: admin)
    text = document.foi_attachment.reload.file.download.force_encoding('UTF-8')

    expect(text).to include('Ask [name] Jones')
    expect(text).to include('café hours')
    expect(text).not_to include(email)
  end
end
