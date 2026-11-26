require 'tmpdir'

module DisclosuresHelpers
  # Reset session so switching accounts drops the previous sign-in.
  def sign_in(user)
    reset!
    super
  end

  # Compatible admin URLs preserve the HTTP method and submitted form.
  def document_request(method, path, **options)
    public_send(method, path, **options)
    return unless response.status == 307

    expect(response.location).
      to match(%r{\Ahttp://www\.example\.com/admin/documents/})
    public_send(method, response.location, **options)
  end

  def document_from_attachment(attachment, by:, kind: 'released_records', ready: true)
    document = Disclosures::Creation.new(user: by,
                                         attachment: attachment,
                                         kind: kind).create!
    document.reload
    expect(document).to be_servable if ready
    document
  end

  def delivered_document(request, name, type, bytes, by: request.user, kind: 'released_records', ready: true)
    message = AttachmentFixtures.deliver(request, [[name, type, bytes]])
    attachment = file_in(message, name)
    read_by_analyzer(attachment)
    document_from_attachment(attachment, by: by, kind: kind, ready: ready)
  end

  def file_in(reply, name)
    reply.get_attachments_for_display.find { |part| part.filename == name }
  end

  def publish(document, _version = nil, by:, **_options)
    document.reload
    Disclosures::Publication.new(document, user: by).publish!
    document.reload.tap { |published| expect(published).to be_listed }
  end

  # Runs StoreTextJob then SuggestJob (StoreTextJob enqueues SuggestJob on
  # completion) for replies delivered before or inside the block.
  def suggest_documents(&block)
    jobs = [IncomingMessage::StoreTextJob, Disclosures::SuggestJob]
    return perform_enqueued_jobs(only: jobs, &block) if block

    jobs.each { |job| perform_enqueued_jobs(only: job) }
  end

  # As if ExcelAnalyzer's job had run and found nothing: until it has, a new
  # spreadsheet is kept from its requester (Disclosures::SpreadsheetHold).
  def read_by_analyzer(attachment)
    blob = attachment.file.blob
    blob.update!(metadata: blob.metadata.merge(analyzed: true))
  end

  def ocr_tools?
    IncomingAttention::Outcome::Ocr.available?
  end
end

RSpec.shared_context 'with document OCR off' do
  around do |example|
    with_setting(Disclosures, :ocr, false) { example.run }
  end
end

RSpec.shared_context 'with production error pages' do
  before do
    allow(Rails.application.config).
      to receive(:consider_all_requests_local).and_return(false)
  end
end

# Manage's replacement clears preview folders by attachment id, and the
# development workspace's ids overlap the test ones.
RSpec.shared_context 'with a separate Manage workspace' do
  around do |example|
    Dir.mktmpdir('attachment-management') do |dir|
      with_setting(AttachmentManagement, :workspace, dir) { example.run }
    end
  end
end

# Disabling requester_editing closes the publish flow and keeps Manage.
RSpec.shared_context 'with the publish flow off' do
  around do |example|
    with_setting(Disclosures, :requester_editing, false) { example.run }
  end
end
