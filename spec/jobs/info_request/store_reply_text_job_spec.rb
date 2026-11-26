require 'spec_helper'

RSpec.describe InfoRequest::StoreReplyTextJob, type: :job do
  include ActiveJob::TestHelper

  # What is stored, read straight from the database.
  def stored_text(message)
    IncomingMessage.where(id: message.id).pick(:cached_main_body_text_folded)
  end

  let(:user) { FactoryBot.create(:user) }
  let(:message_1) do
    FactoryBot.create(
      :incoming_message,
      info_request: FactoryBot.create(:info_request, user: user)
    )
  end
  let(:message_2) do
    FactoryBot.create(
      :incoming_message,
      info_request: FactoryBot.create(:info_request, user: user)
    )
  end
  let(:other_message) { FactoryBot.create(:incoming_message) }
  let(:messages) { [message_1, message_2, other_message] }

  before { messages }

  it 'stores the text again after an expiry, with a new censor rule, ' \
     'without a reply being read' do
    message_1.store_main_body_text!
    expect(stored_text(message_1)).to eq('hereisthetext')

    perform_enqueued_jobs(
      only: [InfoRequest::ExpireJob, described_class]
    ) do
      FactoryBot.create(:info_request_censor_rule,
                        censorable: message_1.info_request,
                        text: 'hereisthetext', replacement: '[gone]')
    end

    expect(stored_text(message_1)).to eq('[gone]')
  end

  it 'stores the text for one request' do
    described_class.new.perform(message_1.info_request)
    expect(messages.map { stored_text(_1) }).to eq(['hereisthetext', nil, nil])
  end

  it "stores the text for a user's requests" do
    described_class.new.perform(user)
    expect(messages.map { stored_text(_1) }).
      to eq(['hereisthetext', 'hereisthetext', nil])
  end

  it "stores the text for an authority's requests" do
    described_class.new.perform(other_message.info_request.public_body)
    expect(messages.map { stored_text(_1) }).to eq([nil, nil, 'hereisthetext'])
  end

  it 'stores the text for every request' do
    described_class.new.perform(InfoRequest)
    expect(messages.map { stored_text(_1) }).to all(eq('hereisthetext'))
  end

  it 'parses a reply nothing had parsed' do
    message = FactoryBot.create(:incoming_message, :unparsed)

    described_class.new.perform(message.info_request)

    expect(message.reload.last_parsed).to be_present
    expect(stored_text(message)).to be_present
  end

  it 'passes over a reply whose text is already stored' do
    message_1.update!(cached_main_body_text_folded: 'stored',
                      cached_main_body_text_unfolded: 'stored')
    tried = []
    allow_any_instance_of(IncomingMessage).
      to receive(:store_main_body_text!).and_wrap_original do |original|
        tried << original.receiver.id
        original.call
      end

    described_class.new.perform(user)

    expect(tried).to eq([message_2.id])
    expect(stored_text(message_1)).to eq('stored')
  end

  it 'leaves a reply whose text cannot be stored to the first read, and ' \
     'stores the rest' do
    allow_any_instance_of(IncomingMessage).
      to receive(:store_main_body_text!).and_wrap_original do |original|
        raise 'cannot be stored' if original.receiver.id == message_1.id

        original.call
      end

    described_class.new.perform(user)

    expect(stored_text(message_1)).to be_nil
    expect(stored_text(message_2)).to eq('hereisthetext')
  end

  it 'does not build text that was stored after the replies were listed' do
    built = []
    allow_any_instance_of(IncomingMessage).
      to receive(:build_main_body_text).and_wrap_original do |original|
        built << original.receiver.id
        original.call
        # A page reads the next reply while this one is in hand.
        if original.receiver.id == message_1.id
          IncomingMessage.find(message_2.id).get_main_body_text_folded
        end
      end

    described_class.new.perform(user)

    expect(built).to eq([message_1.id, message_2.id])
    expect(stored_text(message_2)).to eq('hereisthetext')
  end

  describe 'when the database fails' do
    # The first try of the second reply fails as the database would.
    def fail_once(error)
      failed = false
      allow_any_instance_of(IncomingMessage).
        to receive(:store_main_body_text!).and_wrap_original do |original|
          if original.receiver.id == message_2.id && !failed
            failed = true
            raise error
          end

          original.call
        end
    end

    [ActiveRecord::Deadlocked, ActiveRecord::ConnectionNotEstablished,
     ActiveRecord::ConnectionFailed, ActiveRecord::LockWaitTimeout].
      each do |error|
        it "raises #{error.name.demodulize}, passing no reply over" do
          fail_once(error)

          expect { described_class.new.perform(user) }.to raise_error(error)
          expect(described_class).not_to have_been_enqueued
          expect(stored_text(message_1)).to eq('hereisthetext')
          expect(stored_text(message_2)).to be_nil
        end
      end

    it 'is run again from the same reply, which is then stored' do
      fail_once(ActiveRecord::Deadlocked)

      perform_enqueued_jobs(only: described_class) do
        described_class.perform_later(user)
      end

      expect([message_1, message_2].map { stored_text(_1) }).
        to all(eq('hereisthetext'))
    end

    it 'still passes over a reply the database refuses for itself' do
      fail_once(ActiveRecord::StatementInvalid)

      described_class.new.perform(user)

      expect(stored_text(message_1)).to eq('hereisthetext')
      expect(stored_text(message_2)).to be_nil
    end
  end

  describe 'in batches' do
    let(:message_3) do
      FactoryBot.create(
        :incoming_message,
        info_request: FactoryBot.create(:info_request, user: user)
      )
    end
    let(:messages) { [message_1, message_2, message_3] }

    before { stub_const("#{described_class}::BATCH", 2) }

    it 'stores one batch, then queues itself for the replies after it' do
      expect { described_class.new.perform(user) }.
        to have_enqueued_job(described_class).
        with(user, after: message_2.id).on_queue('low')
      expect(messages.map { stored_text(_1) }).
        to eq(['hereisthetext', 'hereisthetext', nil])
    end

    it 'reaches every reply, past ones whose text cannot be stored' do
      allow_any_instance_of(IncomingMessage).
        to receive(:store_main_body_text!).and_wrap_original do |original|
          raise 'cannot be stored' if original.receiver.id <= message_2.id

          original.call
        end

      perform_enqueued_jobs { described_class.perform_later(user) }

      expect(messages.map { stored_text(_1) }).
        to eq([nil, nil, 'hereisthetext'])
    end

    it 'stops starting replies when its time is up, and queues itself for ' \
       'the rest' do
      stub_const("#{described_class}::TIME", 0)

      expect { described_class.new.perform(user) }.
        to have_enqueued_job(described_class).with(user, after: message_1.id)
      expect(messages.map { stored_text(_1) }).
        to eq(['hereisthetext', nil, nil])

      perform_enqueued_jobs { described_class.perform_later(user) }
      expect(messages.map { stored_text(_1) }).to all(eq('hereisthetext'))
    end

    it 'works through every request by way of the queue' do
      perform_enqueued_jobs(only: described_class) do
        described_class.perform_later(InfoRequest)
      end

      expect(messages.map { stored_text(_1) }).to all(eq('hereisthetext'))
      expect(described_class).not_to have_been_enqueued
    end

    it 'queues nothing more after the last batch' do
      expect { described_class.new.perform(user, after: message_2.id) }.
        not_to have_enqueued_job(described_class)
      expect(messages.map { stored_text(_1) }).
        to eq([nil, nil, 'hereisthetext'])
    end
  end
end
