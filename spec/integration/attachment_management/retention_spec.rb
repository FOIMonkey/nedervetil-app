require 'spec_helper'

RSpec.describe 'Attachment management draft lifecycle' do
  include ActiveJob::TestHelper

  include_context 'with a separate Manage workspace'

  let(:owner) { FactoryBot.create(:user) }
  let(:info_request) { FactoryBot.create(:info_request, user: owner) }
  let(:message) do
    AttachmentFixtures.deliver(
      info_request,
      [['letter.pdf', 'application/pdf',
        AttachmentFixtures.pdf(
          pages: [AttachmentFixtures.letter_page(secret: 'Alice Synthetic')]
        )]]
    )
  end
  let(:pdf) { message.get_attachments_for_display.first }
  let(:revisions) { AttachmentManagement::Revision }
  let(:source_sha256) do
    Digest::SHA256.hexdigest(FoiAttachment.find(pdf.id).body.to_s)
  end

  def previews_for(record)
    att = FoiAttachment.find(record.id)
    bytes = att.body.to_s
    AttachmentManagement::Previews.new(
      attachment_id: att.id,
      sha256: Digest::SHA256.hexdigest(bytes),
      content_type: att.content_type
    ) { bytes }
  end

  def draft(status: 'processing', **attributes)
    revisions.create!(
      foi_attachment: pdf, user: owner, kind: 'pdf_redaction', status: status,
      source_sha256: source_sha256,
      source_content_type: 'application/pdf', source_filename: 'letter.pdf',
      instructions: {
        'boxes' => { '1' => [AttachmentFixtures.letter_secret_box] }
      },
      **attributes
    )
  end

  def with_file(revision)
    revision.output.attach(io: StringIO.new('%PDF-1.4 synthetic draft output'),
                           filename: 'd.pdf', content_type: 'application/pdf')
    revision.update!(
      output_sha256: Digest::SHA256.hexdigest('%PDF-1.4 synthetic draft output')
    )
    revision
  end

  describe 'closing a draft while it is processing [P2]' do
    it 'keeps a draft discarded just before processing finishes discarded, with no file' do
      revision = draft
      allow_any_instance_of(AttachmentManagement::Processor).
        to receive(:finish).and_wrap_original do |finish, *args|
          revisions.find(revision.id).discard!
          finish.call(*args)
        end

      AttachmentManagement::ProcessJob.perform_now(revision.id)

      revision.reload
      expect(revision).to be_discarded
      expect(revision.output).not_to be_attached
      expect(revision.output_sha256).to be_nil
    end

    it 'keeps a superseded draft superseded when its processing finishes' do
      revision = draft
      allow_any_instance_of(AttachmentManagement::Processor).
        to receive(:finish).and_wrap_original do |finish, *args|
          revisions.find(revision.id).leave!('superseded')
          finish.call(*args)
        end
      AttachmentManagement::Processor.new(revision).run
      expect(revision.reload).to be_superseded
      expect(revision.output).not_to be_attached
    end

    it 'doesn’t mark a discarded draft failed when its processing fails afterwards' do
      revision = draft
      allow_any_instance_of(AttachmentManagement::Engines::Raster).
        to receive(:redact_pdf) do
          revisions.find(revision.id).discard!
          raise AttachmentManagement::Command::Failed, 'synthetic failure'
        end
      AttachmentManagement::Processor.new(revision).run
      expect(revision.reload).to be_discarded
      expect(revision.error).to be_nil
    end

    it 'doesn’t revive a closed draft when the job crashes' do
      revision = draft
      allow_any_instance_of(AttachmentManagement::Processor).
        to receive(:run) do
          revisions.find(revision.id).discard!
          raise 'synthetic crash'
        end
      # ApplicationJob catches the error and schedules a retry, which finds
      # the draft closed and stops.
      AttachmentManagement::ProcessJob.perform_now(revision.id)
      expect(revision.reload).to be_discarded
      expect(revision.error).to be_nil
    end

    it 'only closes a draft that is still open' do
      revision = with_file(draft(status: 'ready'))
      expect(revision.discard!).to be true
      expect(revision.leave!('expired')).to be false
      expect(revision.reload).to be_discarded
      expect(revision.output).not_to be_attached
    end
  end

  describe 'retention [P2]' do
    # The source is read on the real clock: travel_to freezes time, and
    # FoiAttachment#masked? needs masked_at in the past, so a read inside it
    # would wait.
    before { source_sha256 }

    def run(now: Time.current)
      AttachmentManagement::Retention.new.run(now: now)
    end

    it 'expires drafts left unconfirmed and deletes their files, keeping the record' do
      stale = travel_to(8.days.ago) { with_file(draft(status: 'ready')) }
      stuck = travel_to(8.days.ago) { draft(status: 'processing') }
      recent = with_file(draft(status: 'ready'))

      result = run
      expect(result.expired).to eq(2)
      expect(stale.reload).to be_expired
      expect(stale.output).not_to be_attached
      expect(stale.output_sha256).to be_present
      expect(stuck.reload).to be_expired
      expect(recent.reload).to be_ready
      expect(recent.output).to be_attached
    end

    it 'follows the configured time' do
      with_setting(AttachmentManagement, :draft_retention, 1.day) do
        old = travel_to(2.days.ago) { with_file(draft(status: 'ready')) }
        run
        expect(old.reload).to be_expired
      end
    end

    it 'deletes any file a closed draft still holds' do
      leftovers = %w[applied failed discarded superseded].map do |status|
        with_file(draft(status: 'ready')).
          tap { |r| r.update_columns(status: status) }
      end
      expect(run.files_deleted).to eq(4)
      leftovers.each { |r| expect(r.reload.output).not_to be_attached }
    end

    it 'deletes page images nobody has made or used lately, and keeps recent ones' do
      old_png = previews_for(pdf).png(1)
      other = AttachmentManagement::Previews.dir(pdf.id + 1, 'b' * 64)
      FileUtils.mkdir_p(other)
      FileUtils.touch(other.join('page-1.png'))

      [old_png, old_png.dirname.join('file'), old_png.dirname,
       old_png.dirname.join('pages.txt')].each do |path|
        if File.exist?(path)
          File.utime(2.days.ago.to_time, 2.days.ago.to_time, path)
        end
      end

      expect(run.previews_deleted).to eq(1)
      expect(old_png.dirname).not_to exist
      expect(other).to exist
    end

    it 'counts serving a page image as use' do
      previews = previews_for(pdf)
      png = previews.png(1)
      old = 2.days.ago.to_time
      png.dirname.children.each { |path| File.utime(old, old, path) }
      File.utime(old, old, png.dirname)

      previews.png(1) # served again
      expect(run.previews_deleted).to eq(0)
      expect(png).to exist
    end

    it 'runs daily from normal use, once a day' do
      expect { AttachmentManagement::CleanupJob.enqueue_if_due }.
        to have_enqueued_job(AttachmentManagement::CleanupJob)
      expect { AttachmentManagement::CleanupJob.enqueue_if_due }.
        not_to have_enqueued_job(AttachmentManagement::CleanupJob)
      expect do
        AttachmentManagement::CleanupJob.enqueue_if_due(now: 25.hours.from_now)
      end.to have_enqueued_job(AttachmentManagement::CleanupJob)
      expect(AttachmentManagement::CleanupJob.perform_now).
        to be_a(AttachmentManagement::Retention::Result)
    end
  end

  describe 'a confirmed draft' do
    include_context 'with the publish flow off'

    it 'keeps its record and digests but not its copy of the file' do
      post '/profile/sign_in', params: {
        user_signin: { email: owner.email, password: 'jonespassword' }
      }
      post manage_attachment_revisions_path(pdf),
           params: {
             kind: 'pdf_redaction',
             boxes: { '1' => [AttachmentFixtures.letter_secret_box] }.to_json
           }
      perform_enqueued_jobs(only: AttachmentManagement::ProcessJob)
      revision = revisions.last
      post apply_manage_attachment_revision_path(pdf, revision),
           params: { reviewed: '1', reason: 'Synthetic',
                     output_sha256: revision.output_sha256 }

      revision.reload
      expect(revision).to be_applied
      expect(revision.output).not_to be_attached
      expect(Digest::SHA256.hexdigest(FoiAttachment.find(pdf.id).body)).
        to eq(revision.output_sha256)
      get file_manage_attachment_revision_path(pdf, revision)
      expect(response).to have_http_status(:not_found)
    end

    it 'says an expired draft must be made again, and can’t be confirmed' do
      revision = with_file(draft(status: 'ready'))
      revision.leave!('expired')
      post '/profile/sign_in', params: {
        user_signin: { email: owner.email, password: 'jonespassword' }
      }
      get manage_attachment_revision_path(pdf, revision)
      expect(response.body).to include('wasn’t confirmed in time')
      post apply_manage_attachment_revision_path(pdf, revision),
           params: { reviewed: '1', reason: 'x',
                     output_sha256: revision.output_sha256 }
      expect(flash[:error]).to include('not ready')
      expect(AttachmentManagement::Revision.
               where(foi_attachment_id: pdf.id, status: 'applied')).to be_empty
    end
  end
end
