require 'spec_helper'

RSpec.describe Disclosures::RequesterRedaction do
  include DisclosuresHelpers
  include SettingsHelpers
  include_context 'with document OCR off'

  let(:owner) do
    FactoryBot.create(:user, name: 'Rowan Requester',
                             email: 'rowan.requester@example.org')
  end
  let(:info_request) { FactoryBot.create(:info_request, user: owner) }

  def receive_reply(body:, files: {})
    mail = Mail.new
    mail.from = info_request.public_body.request_email
    mail.to = info_request.incoming_email
    mail.subject = 'Response'
    mail.text_part = Mail::Part.new(content_type: 'text/plain; charset=UTF-8',
                                    body: body)
    files.each do |filename, content|
      mail.add_file(filename: filename, content: content)
    end
    message = info_request.receive(Mail.from_source(mail.encoded))
    IncomingMessage::StoreTextJob.perform_now(message)
    message.reload
  end

  def make_document(attachment)
    Disclosures::Document.create!(
      info_request: info_request,
      public_body: info_request.public_body,
      incoming_message: attachment.incoming_message,
      foi_attachment: attachment,
      source_kind: 'attachment',
      kind: 'decision_letter',
      title: 'Reply text',
      released_on: Date.current,
      state: 'draft',
      created_by: owner
    )
  end

  def redaction(document)
    described_class.new(document, user: owner, ability: Ability.new(owner))
  end

  describe '#apply!' do
    let(:message) { receive_reply(body: 'Dear Rowan Requester, phone 12345.') }
    let(:part) { message.get_main_body_text_part }
    let(:document) { make_document(part) }
    let(:edit) do
      { kind: 'text_edit', text: 'Dear Rowan Requester, phone [redacted].' }
    end

    it 'applies the edit, publishes the file and says so' do
      result = with_setting(Disclosures, :review_requester_redactions, false) do
        redaction(document).apply!(**edit)
      end

      expect(result.notice).to eq('Redactions saved and shared publicly.')
      expect(result.continue_from).to be_nil
      expect(part.reload.body).to include('[redacted]')
      expect(part.prominence).to eq('public')
      expect(document.reload.state).to eq('published')
    end

    it 'applies the edit and says an admin will check it when it needs ' \
       'review' do
      result = with_setting(Disclosures, :review_requester_redactions, true) do
        redaction(document).apply!(**edit)
      end

      expect(result.notice).to eq(
        'Redactions saved. An admin will check this file before it goes public.'
      )
      expect(result.continue_from).to be_nil
      expect(part.reload.body).to include('[redacted]')
      expect(part.prominence).to eq('requester_only')
      expect(document.reload.state).to eq('draft')
    end

    it 'refuses a kind of redaction the requester may not make on the file' do
      reply = receive_reply(body: 'Cover note.',
                            files: { 'notes.txt' => "A secret note\n" })
      notes = reply.foi_attachments.find_by!(filename: 'notes.txt')

      expect do
        redaction(make_document(notes)).
          apply!(kind: 'text_edit', text: "A [redacted] note\n")
      end.to raise_error(Disclosures::Error::Refused,
                         'An admin must handle redactions on this file.')
      expect(notes.reload.body).to include('secret')
      expect(AttachmentManagement::Revision.count).to eq(0)
    end

    it 'refuses when the file is no longer there' do
      allow(document).to receive(:foi_attachment).and_return(nil)

      expect { redaction(document).apply!(**edit) }.
        to raise_error(Disclosures::Error::Refused,
                       'This file is no longer there.')
    end
  end
end
