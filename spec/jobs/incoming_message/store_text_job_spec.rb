require 'spec_helper'

RSpec.describe IncomingMessage::StoreTextJob, type: :job do
  include ActiveJob::TestHelper

  def stored(message)
    IncomingMessage.where(id: message.id).
      pick(:last_parsed, :cached_main_body_text_folded)
  end

  def receive_reply(to: info_request.incoming_email)
    receive_incoming_mail('incoming-request-plain.eml', to: to)
    IncomingMessage.order(:id).last
  end

  describe 'when mail arrives' do
    let(:info_request) { FactoryBot.create(:info_request) }

    it 'is queued for the reply, which nothing has parsed yet' do
      receive_incoming_mail('incoming-request-plain.eml',
                            to: info_request.incoming_email)
      message = info_request.incoming_messages.last

      expect(described_class).to have_been_enqueued.with(message).
        on_queue('default')
      expect(stored(message)).to eq([nil, nil])
    end

    it 'parses the mail and stores the text without the reply being read' do
      perform_enqueued_jobs(only: described_class) do
        receive_incoming_mail('incoming-request-plain.eml',
                              to: info_request.incoming_email)
      end
      last_parsed, text = stored(info_request.incoming_messages.last)

      expect(last_parsed).to be_present
      expect(text).to include('No way!')
    end

    it 'does the same for mail filed in the holding pen' do
      perform_enqueued_jobs(only: described_class) do
        receive_incoming_mail('incoming-request-plain.eml',
                              to: 'dummy@localhost')
      end
      message = InfoRequest.holding_pen_request.incoming_messages.last
      last_parsed, text = stored(message)

      expect(last_parsed).to be_present
      expect(text).to include('No way!')
    end

    it 'still receives the mail when the job cannot be queued' do
      allow(described_class).to receive(:perform_later).
        and_raise(RedisClient::CannotConnectError)

      receive_incoming_mail('incoming-request-plain.eml',
                            to: info_request.incoming_email)

      message = info_request.incoming_messages.last
      expect(message).to be_present
      expect(message.get_main_body_text_folded).to include('No way!')
    end
  end

  describe 'when the mail can’t be read' do
    let(:info_request) { FactoryBot.create(:info_request) }
    let(:reads) { [] }

    before do
      allow_any_instance_of(described_class).
        to receive(:send_exception_notifications?).and_return(true)
      allow(ExceptionNotifier).to receive(:notify_exception)
      allow(Rails.logger).to receive(:warn)
    end

    def refuse_reads(times)
      allow(MailHandler::Reading).to receive(:of).
        and_wrap_original do |original, source, **options|
          reads << options
          if reads.size <= times
            raise MailHandler::ReadRefused, 'the mail cell is down'
          end

          original.call(source, **options)
        end
    end

    it 'tries twelve times, stores nothing, and then notifies once' do
      refuse_reads(100)

      message = nil
      perform_enqueued_jobs(only: described_class) { message = receive_reply }

      expect(reads.size).to eq(12)
      expect(stored(message)).to eq([nil, nil])
      expect(message.foi_attachments.reload).to be_empty
      expect(described_class).not_to have_been_enqueued
      expect(ExceptionNotifier).to have_received(:notify_exception).once.with(
        instance_of(MailHandler::ReadRefused),
        data: hash_including(job: 'IncomingMessage::StoreTextJob')
      )
    end

    it 'spreads its tries over about eleven hours' do
      waits = (1...described_class::READ_ATTEMPTS).sum do |tried|
        (tried**4) + 2
      end
      expect(waits).to be_between(10.hours, 12.hours)
    end

    it 'parses the mail and stores the text once it can be read, with no ' \
       'notification' do
      refuse_reads(3)

      message = nil
      perform_enqueued_jobs(only: described_class) { message = receive_reply }

      expect(reads.size).to eq(4)
      expect(stored(message).first).to be_present
      expect(stored(message).last).to include('No way!')
      expect(ExceptionNotifier).not_to have_received(:notify_exception)
    end

    it 'does not take the note a page would show for the reply’s text' do
      refuse_reads(100)

      message = nil
      perform_enqueued_jobs(only: described_class) { message = receive_reply }

      expect(IncomingMessage.find(message.id).cached_main_body_text_folded).
        to be_nil
    end
  end

  describe "the reply's AI reading" do
    let(:info_request) { FactoryBot.create(:info_request) }

    let(:readings) { [] }

    before do
      allow(IncomingAttention::Config).to receive(:enabled?).and_return(true)
      allow(IncomingAttention::Job).to receive(:perform_later) do |id|
        readings << IncomingAttention::Prediction.find(id).incoming_message_id
      end
      allow_any_instance_of(described_class).
        to receive(:send_exception_notifications?).and_return(true)
      allow(ExceptionNotifier).to receive(:notify_exception)
    end

    it 'is not queued when the mail arrives, only this job' do
      message = receive_reply

      expect(readings).to be_empty
      expect(IncomingAttention::Prediction.for_message(message).status).
        to eq('pending')
      expect(described_class).to have_been_enqueued.with(message)
    end

    it 'is queued once, when the text is stored' do
      stored_when_queued = nil
      allow(IncomingAttention::Job).to receive(:perform_later) do |id|
        message = IncomingAttention::Prediction.find(id).incoming_message
        readings << message.id
        stored_when_queued = stored(message).last
      end

      message = nil
      perform_enqueued_jobs(only: described_class) { message = receive_reply }

      expect(readings).to eq([message.id])
      expect(stored_when_queued).to include('No way!')
      expect(described_class).not_to have_been_enqueued
      expect(ExceptionNotifier).not_to have_received(:notify_exception)
    end

    it 'is queued when the job gives up on the text' do
      tries = 0
      allow_any_instance_of(IncomingMessage).
        to receive(:build_main_body_text) do
          expect(readings).to be_empty
          tries += 1
          raise AttachmentToText::ConversionFailed
        end

      message = nil
      perform_enqueued_jobs(only: described_class) { message = receive_reply }

      expect(tries).to eq(3)
      expect(readings).to eq([message.id])
    end

    it 'is queued when the job gives up on mail that can’t be read' do
      allow(MailHandler::Reading).to receive(:of) do
        expect(readings).to be_empty
        raise MailHandler::ReadRefused, 'the mail cell is down'
      end
      allow(Rails.logger).to receive(:warn)

      message = nil
      perform_enqueued_jobs(only: described_class) { message = receive_reply }

      expect(readings).to eq([message.id])
      expect(stored(message)).to eq([nil, nil])
    end

    it 'is queued when the job is dropped for an erased email' do
      message = receive_reply
      allow_any_instance_of(RawEmail).to receive(:erased?).and_return(true)

      perform_enqueued_jobs(only: described_class)

      expect(readings).to eq([message.id])
      expect(stored(message)).to eq([nil, nil])
    end

    it 'is queued as the mail arrives when this job cannot be queued' do
      allow(described_class).to receive(:perform_later).
        and_raise(RedisClient::CannotConnectError)

      message = receive_reply

      expect(readings).to eq([message.id])
    end

    it 'is queued as the mail arrives when this job is refused' do
      allow(described_class).to receive(:perform_later).and_return(false)

      message = receive_reply

      expect(readings).to eq([message.id])
    end

    it 'is not queued for mail in the holding pen' do
      perform_enqueued_jobs(only: described_class) do
        receive_reply(to: 'dummy@localhost')
      end

      expect(readings).to be_empty
    end

    it 'is not queued with AI reading off' do
      allow(IncomingAttention::Config).to receive(:enabled?).and_return(false)

      perform_enqueued_jobs(only: described_class) { receive_reply }

      expect(readings).to be_empty
    end

    it 'is queued once when the suggestion of documents cannot be' do
      allow(Disclosures::SuggestJob).to receive(:perform_later).
        and_raise(RedisClient::CannotConnectError)

      message = nil
      perform_enqueued_jobs(only: described_class) { message = receive_reply }

      expect(readings).to eq([message.id])
      expect(described_class).not_to have_been_enqueued
      expect(ExceptionNotifier).not_to have_received(:notify_exception)
    end

    it 'is queued by its recovery task for a reply nothing has parsed, ' \
       'should this job be lost' do
      message = receive_reply
      row = IncomingAttention::Prediction.for_message(message)
      row.update_columns(updated_at: 6.minutes.ago)

      IncomingAttention::Recovery.run

      expect(stored(message)).to eq([nil, nil])
      expect(readings).to eq([message.id])
      expect(row.reload.status).to eq('pending')
    end
  end

  describe 'the suggestion of documents from the reply' do
    let(:info_request) { FactoryBot.create(:info_request) }

    it 'is not queued when the mail arrives, only this job' do
      message = receive_reply

      expect(Disclosures::SuggestJob).not_to have_been_enqueued
      expect(described_class).to have_been_enqueued.with(message)
    end

    it 'is queued once, when the text is stored' do
      stored_when_queued = []
      allow(Disclosures::SuggestJob).to receive(:perform_later) do |id|
        stored_when_queued << IncomingMessage.where(id: id).
          pick(:id, :cached_main_body_text_folded)
      end

      message = nil
      perform_enqueued_jobs(only: described_class) { message = receive_reply }

      expect(stored_when_queued).to match([[message.id, /No way!/]])
    end

    it 'is queued when the job gives up on the text' do
      allow_any_instance_of(IncomingMessage).
        to receive(:build_main_body_text) do
          expect(Disclosures::SuggestJob).not_to have_been_enqueued
          raise AttachmentToText::ConversionFailed
        end

      message = nil
      perform_enqueued_jobs(only: described_class) { message = receive_reply }

      expect(Disclosures::SuggestJob).
        to have_been_enqueued.with(message.id).exactly(:once)
    end

    it 'is queued when the job is dropped for an erased email' do
      message = receive_reply
      allow_any_instance_of(RawEmail).to receive(:erased?).and_return(true)

      perform_enqueued_jobs(only: described_class)

      expect(Disclosures::SuggestJob).
        to have_been_enqueued.with(message.id).exactly(:once)
    end

    it 'is queued as the mail arrives when this job cannot be queued' do
      allow(described_class).to receive(:perform_later).
        and_raise(RedisClient::CannotConnectError)

      message = receive_reply

      expect(Disclosures::SuggestJob).
        to have_been_enqueued.with(message.id).exactly(:once)
    end

    it 'is not queued for mail in the holding pen' do
      perform_enqueued_jobs(only: described_class) do
        receive_reply(to: 'dummy@localhost')
      end

      expect(Disclosures::SuggestJob).not_to have_been_enqueued
    end

    it 'is queued once when the AI reading cannot be' do
      allow(IncomingAttention::Config).to receive(:enabled?).and_return(true)
      allow_any_instance_of(IncomingAttention::Prediction).
        to receive(:enqueue!).and_raise(ActiveRecord::ConnectionNotEstablished)

      message = nil
      perform_enqueued_jobs(only: described_class) { message = receive_reply }

      expect(Disclosures::SuggestJob).
        to have_been_enqueued.with(message.id).exactly(:once)
      expect(described_class).not_to have_been_enqueued
    end
  end

  describe '#perform' do
    let(:message) { FactoryBot.create(:incoming_message) }

    it 'stores the text' do
      described_class.new.perform(message)
      expect(stored(message).last).to eq('hereisthetext')
    end

    it 'leaves text that is already stored' do
      message.update!(cached_main_body_text_folded: 'stored',
                      cached_main_body_text_unfolded: 'stored')
      described_class.new.perform(message)
      expect(stored(message).last).to eq('stored')
    end

    it 'stores the text of a reply with an empty body, and is not tried ' \
       'again' do
      message.foi_attachments.first.update!(body: '')

      expect { described_class.perform_now(message) }.
        not_to have_enqueued_job(described_class)
      expect(stored(message).last).to eq('')
    end

    it 'stores the text of a reply whose body was erased, and is not tried ' \
       'again' do
      message.foi_attachments.first.update!(erased_at: Time.zone.now)

      expect { described_class.perform_now(message) }.
        not_to have_enqueued_job(described_class)
      expect(stored(message).last).to eq('')
    end

    it 'raises, to be tried again, when the text is not stored' do
      allow(message).to receive(:build_main_body_text).
        and_raise(AttachmentToText::ConversionFailed)

      expect { described_class.new.perform(message) }.
        to raise_error(IncomingMessage::MainBody::NotStored)
      expect(stored(message).last).to be_nil
    end

    it 'is tried again later when the text is not stored' do
      allow(message).to receive(:build_main_body_text).
        and_raise(AttachmentToText::ConversionFailed)

      expect { described_class.perform_now(message) }.
        to have_enqueued_job(described_class).with(message)
    end

    it 'gives up after three tries, with no exception notification' do
      tries = 0
      allow_any_instance_of(IncomingMessage).
        to receive(:build_main_body_text) do
          tries += 1
          raise AttachmentToText::ConversionFailed
        end
      allow_any_instance_of(described_class).
        to receive(:send_exception_notifications?).and_return(true)
      allow(ExceptionNotifier).to receive(:notify_exception)

      # Creating the reply queues its job.
      perform_enqueued_jobs(only: described_class) { message }

      expect(tries).to eq(3)
      expect(ExceptionNotifier).not_to have_received(:notify_exception)
      expect(described_class).not_to have_been_enqueued
      expect(stored(message).last).to be_nil
    end

    it 'is dropped for an email erased before it was parsed' do
      message = FactoryBot.create(:incoming_message, :unparsed)
      allow(message.raw_email).to receive(:erased?).and_return(true)

      expect { described_class.perform_now(message) }.
        not_to have_enqueued_job(described_class)
      expect(stored(message)).to eq([nil, nil])
    end
  end
end
