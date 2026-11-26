require 'spec_helper'

RSpec.describe 'Independent stale attachment form contracts', type: :request do
  include_context 'with the publish flow off'
  include_context 'with production error pages'
  include_context 'with a separate Manage workspace'
  include ActiveJob::TestHelper
  let(:owner) { FactoryBot.create(:user) }
  let(:request_record) { FactoryBot.create(:info_request, user: owner) }
  let(:letter) do
    AttachmentFixtures.pdf(
      pages: [AttachmentFixtures.letter_page(secret: 'Rowan Example')]
    )
  end
  let(:attachment) do
    message = AttachmentFixtures.deliver(
      request_record, [['letter.pdf', 'application/pdf', letter]]
    )
    message.get_attachments_for_display.
      find { |part| part.filename == 'letter.pdf' }
  end
  let!(:original) { FoiAttachment.find(attachment.id).body }
  let(:boxes) { { '1' => [AttachmentFixtures.letter_secret_box] }.to_json }

  around do |example|
    keeping_settings(AttachmentManagement, :requester_access) { example.run }
  end

  def issued_confirmation(draft = { kind: 'pdf_redaction', boxes: boxes })
    sign_in(owner)
    post manage_attachment_revisions_path(attachment), params: draft
    perform_enqueued_jobs(only: AttachmentManagement::ProcessJob)
    revision = AttachmentManagement::Revision.
               where(foi_attachment_id: attachment.id).last.reload
    expect(revision).to be_ready
    get manage_attachment_revision_path(attachment, revision)
    expect(response).to have_http_status(:ok)
    [revision, { reviewed: '1', reason: 'Synthetic stale form check',
                 output_sha256: revision.output_sha256 }]
  end

  %i[suspension reassignment access_closed].each do |change|
    it "refuses an issued confirmation after #{change}, with original bytes and draft preserved" do
      revision, form = issued_confirmation
      case change
      when :suspension then owner.update!(ban_text: 'Synthetic suspension')
      when :reassignment
        request_record.update!(user: FactoryBot.create(:user))
      when :access_closed then AttachmentManagement.requester_access = 'none'
      end
      2.times do
        post apply_manage_attachment_revision_path(attachment, revision),
params: form
        expect(response).to have_http_status(:not_found)
      end
      expect(revision.reload).to be_ready
      expect(FoiAttachment.find(attachment.id).body).to eq(original)
    end
  end

  it 'rechecks replacement authority when an already-issued free-edit confirmation is replayed' do
    AttachmentManagement.requester_access = 'replace'
    revision, form = issued_confirmation(
      kind: 'upload',
      file: Rack::Test::UploadedFile.new(
        StringIO.new("Invented Person\n"), 'text/plain', true,
        original_filename: 'invented.txt'
      )
    )
    AttachmentManagement.requester_access = nil
    2.times do
      post apply_manage_attachment_revision_path(attachment, revision),
params: form
      expect(flash[:error]).to include('Only an admin can confirm')
    end
    expect(revision.reload).to be_ready
    expect(FoiAttachment.find(attachment.id).body).to eq(original)
  end

  it 'still allows a previously issued redaction when permission remains valid' do
    revision, form = issued_confirmation
    post apply_manage_attachment_revision_path(attachment, revision),
params: form
    expect(revision.reload).to be_applied
    expect(FoiAttachment.find(attachment.id).body).not_to eq(original)
  end
end
