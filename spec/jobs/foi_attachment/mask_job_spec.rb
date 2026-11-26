require 'spec_helper'

RSpec.describe FoiAttachment::MaskJob, type: :job do
  let(:info_request) { FactoryBot.create(:info_request_with_html_attachment) }
  let(:incoming_message) { info_request.incoming_messages.first }
  let(:attachment) { incoming_message.foi_attachments.last }

  def perform
    described_class.new.perform(attachment)
  end

  describe 'uniqueness' do
    let(:attachment_1) { incoming_message.foi_attachments.first }
    let(:attachment_2) { incoming_message.foi_attachments.last }

    before { described_class.unlock! }
    after { described_class.unlock! }

    it 'does not enqueue duplicate jobs for the same attachment' do
      expect {
        described_class.perform_later(attachment_1)
        described_class.perform_later(attachment_1)
      }.to have_enqueued_job(described_class).exactly(:once)
    end

    it 'enqueues jobs for sibling attachments of the same message' do
      expect {
        described_class.perform_later(attachment_1)
        described_class.perform_later(attachment_2)
      }.to have_enqueued_job(described_class).twice
    end
  end

  # The unique lock is taken when the job is queued and, after a run that
  # succeeds, freed by after_perform. A run that raises must free it too, or
  # ApplicationJob's retry_on would find the job's own lock and drop the retry.
  describe 'retrying after an unexpected error' do
    before do
      described_class.unlock!
      attachment # created before the job is queued
      allow_any_instance_of(FoiAttachment).
        to receive(:mask).and_raise(StandardError, 'boom')
    end

    after { described_class.unlock! }

    def queue_job
      described_class.perform_later(attachment).tap { clear_enqueued_jobs }
    end

    def run_as_worker(job)
      ActiveJob::Base.execute(job.serialize)
    end

    def events(name, &block)
      seen = []
      ActiveSupport::Notifications.subscribed(->(event) { seen << event },
                                              name, &block)
      seen
    end

    it 'queues the retry' do
      job = queue_job
      conflicts = nil

      retries = events('enqueue_retry.active_job') do
        conflicts = events('conflict.active_job_uniqueness') do
          expect { run_as_worker(job) }.not_to raise_error
        end
      end

      expect(retries.size).to eq(1)
      expect(conflicts).to be_empty
      expect(enqueued_jobs.size).to eq(1)
      expect(enqueued_jobs.first['job_class']).to eq(described_class.name)
    end

    it 'keeps the queued retry unique' do
      run_as_worker(queue_job)
      expect(enqueued_jobs.size).to eq(1)

      expect { described_class.perform_later(attachment) }.
        not_to have_enqueued_job(described_class)
    end

    it 'frees the lock when the last attempt fails' do
      allow_any_instance_of(described_class).
        to receive(:send_exception_notifications?).and_return(false)
      data = queue_job.serialize.
             merge('exception_executions' => { '[StandardError]' => 4 })

      ActiveJob::Base.execute(data)

      expect(enqueued_jobs).to be_empty
      expect { described_class.perform_later(attachment) }.
        to have_enqueued_job(described_class).exactly(:once)
    end
  end

  describe 'when the queued arguments cannot be loaded' do
    before do
      described_class.unlock!
      attachment # created before the job is queued
    end

    after { described_class.unlock! }

    shared_examples 'frees the lock' do
      it 'discards the job and frees its lock' do
        job = described_class.perform_later(attachment)
        clear_enqueued_jobs
        expect_any_instance_of(FoiAttachment).not_to receive(:mask)
        allow(GlobalID::Locator).to receive(:locate).and_raise(error)

        ActiveJob::Base.execute(job.serialize)

        expect { described_class.perform_later(attachment) }.
          to have_enqueued_job(described_class).exactly(:once)
      end
    end

    context 'because the database connection dropped' do
      let(:error) { ActiveRecord::ConnectionNotEstablished }
      include_examples 'frees the lock'
    end

    context 'because the part has gone' do
      let(:error) { ActiveRecord::RecordNotFound }
      include_examples 'frees the lock'
    end
  end

  describe '#queued_lock_key' do
    it 'matches the key the gem locks' do
      job = described_class.new(attachment)
      expect(job.queued_lock_key).to eq(job.lock_key)
    end
  end

  describe 'while it runs' do
    before { described_class.unlock! }
    after { described_class.unlock! }

    it 'keeps a mask queued for the same part out' do
      job = described_class.perform_later(attachment)
      clear_enqueued_jobs
      queued_while_running = :not_tried
      allow_any_instance_of(FoiAttachment).to receive(:mask) do
        queued_while_running = described_class.perform_later(attachment)
      end

      ActiveJob::Base.execute(job.serialize)

      expect(queued_while_running).to be(false)
      expect(enqueued_jobs).to be_empty
    end
  end

  context 'when masking times out' do
    before do
      allow(attachment).to receive(:apply_censor_rules).and_raise(Regexp::TimeoutError)
      allow_any_instance_of(described_class).
        to receive(:send_exception_notifications?).and_return(true)
      allow(ExceptionNotifier).to receive(:notify_exception)
    end

    it 'records the failure without raising' do
      expect { perform }.to_not raise_error
      expect(attachment.masking_failed_at).to be_present
    end

    it 'notifies once on the first failure' do
      expect(ExceptionNotifier).to receive(:notify_exception).once
      perform
    end

    it 'does not notify when the attachment already failed' do
      attachment.update_column(:masking_failed_at, Time.zone.now)
      expect(ExceptionNotifier).to_not receive(:notify_exception)
      perform
    end
  end

  context 'when a PDF cannot be masked' do
    before do
      allow(attachment).to receive(:apply_censor_rules).
        and_raise(AlaveteliTextMasker::PDFMaskingError, 'qpdf failed')
      allow_any_instance_of(described_class).
        to receive(:send_exception_notifications?).and_return(true)
      allow(ExceptionNotifier).to receive(:notify_exception)
    end

    it 'records the failure without raising' do
      expect { perform }.to_not raise_error
      expect(attachment.masking_failed_at).to be_present
    end

    it 'notifies once, with the reason' do
      message = "PDF masking failed (ID=#{attachment.id}): qpdf failed"
      perform
      expect(ExceptionNotifier).to have_received(:notify_exception).
        with(an_instance_of(AlaveteliTextMasker::PDFMaskingError).
             and(having_attributes(message: message)),
             data: { foi_attachment: attachment.id }).once
    end
  end

  context 'when masking in place' do
    it 'masks the stored file without opening RawEmail' do
      CensorRule.create!(
        text: 'dull', replacement: 'Orange',
        last_edit_editor: 'unknown', last_edit_comment: 'none'
      )
      expect(incoming_message).not_to receive(:parse_raw_email!)
      expect(incoming_message.raw_email).not_to receive(:data)

      perform

      expect(attachment.reload.body).to include('Orange')
      expect(attachment).to be_black_masked
    end
  end
end
