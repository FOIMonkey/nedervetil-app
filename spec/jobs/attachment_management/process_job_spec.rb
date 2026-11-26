require 'spec_helper'

RSpec.describe AttachmentManagement::ProcessJob, type: :job do
  include ActiveJob::TestHelper

  let(:owner) { FactoryBot.create(:user) }
  let(:info_request) { FactoryBot.create(:info_request, user: owner) }
  let(:pdf) do
    AttachmentFixtures.deliver(
      info_request,
      [['letter.pdf', 'application/pdf',
        AttachmentFixtures.pdf(
          pages: [AttachmentFixtures.letter_page(secret: 'Alice Synthetic')]
        )]]
    ).get_attachments_for_display.first
  end
  let!(:revision) do
    AttachmentManagement::Revision.create!(
      foi_attachment: pdf, user: owner, kind: 'pdf_redaction',
      status: 'processing',
      source_sha256: Digest::SHA256.hexdigest(pdf.body.to_s),
      source_content_type: 'application/pdf', source_filename: 'letter.pdf',
      instructions: {
        'boxes' => { '1' => [AttachmentFixtures.letter_secret_box] }
      }
    )
  end
  let(:report_data) do
    { job: 'AttachmentManagement::ProcessJob', job_id: kind_of(String) }
  end

  before do
    allow(AlaveteliConfiguration).to receive(:exception_notifications_from).
      and_return('from@example.com')
    allow(AlaveteliConfiguration).to receive(:exception_notifications_to).
      and_return('to@example.com')
  end

  context 'when processing crashes' do
    let(:crash) { RuntimeError.new('synthetic crash') }

    before do
      processor = instance_double(AttachmentManagement::Processor)
      allow(processor).to receive(:run).and_raise(crash)
      allow(AttachmentManagement::Processor).
        to receive(:new).and_return(processor)
    end

    it 'marks the revision failed and reports the crash once' do
      expect(ExceptionNotifier).to receive(:notify_exception).
        with(crash, data: report_data).once

      perform_enqueued_jobs { described_class.perform_later(revision.id) }

      expect(revision.reload).to be_failed
      expect(revision.error).to eq('Processing failed: RuntimeError')
    end

    it 'reports nothing when the site sends no exception notifications' do
      allow(AlaveteliConfiguration).to receive(:exception_notifications_to).
        and_return('')
      expect(ExceptionNotifier).not_to receive(:notify_exception)

      perform_enqueued_jobs { described_class.perform_later(revision.id) }

      expect(revision.reload).to be_failed
    end
  end

  context 'when the revision cannot be loaded' do
    before do
      allow(AttachmentManagement::Revision).to receive(:find_by).
        and_raise(ActiveRecord::ConnectionNotEstablished)
    end

    it 'tries again, and reports once after the last attempt' do
      expect(ExceptionNotifier).to receive(:notify_exception).
        with(instance_of(ActiveRecord::ConnectionNotEstablished),
             data: report_data).once

      perform_enqueued_jobs { described_class.perform_later(revision.id) }

      expect(AttachmentManagement::Revision).
        to have_received(:find_by).exactly(5).times
      expect(revision.reload).to be_processing
    end
  end
end
