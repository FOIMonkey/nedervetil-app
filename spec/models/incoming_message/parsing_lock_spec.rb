require 'spec_helper'

RSpec.describe IncomingMessage::ParsingLock do
  self.use_transactional_tests = false

  let!(:message) do
    FactoryBot.create(:incoming_message, :with_html_attachment)
  end

  after do
    [message.info_request, message.info_request.user,
     message.info_request.public_body].each(&:destroy)
  end

  def lock_available?(message_id = message.id)
    probe = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        key = "#{described_class::NAMESPACE}, #{Integer(message_id)}"
        acquired = connection.select_value(
          "SELECT pg_try_advisory_lock(#{key})"
        )
        connection.execute("SELECT pg_advisory_unlock(#{key})") if acquired
        acquired
      end
    end
    raise 'lock probe did not finish' unless probe.join(10)

    probe.value
  ensure
    probe&.kill&.join if probe&.alive?
  end

  it 'holds the lock through the block and releases it on return' do
    described_class.synchronize(message) do
      expect(lock_available?).to eq(false)
    end
    expect(lock_available?).to eq(true)
  end

  it 'does not lock another incoming message' do
    other = FactoryBot.create(
      :incoming_message, info_request: message.info_request
    )

    described_class.synchronize(message) do
      expect(lock_available?(other.id)).to eq(true)
    end
  end

  it 'keeps the outer lock held during nested parsing' do
    described_class.synchronize(message) do
      described_class.synchronize(message) { nil }
      expect(lock_available?).to eq(false)
    end
    expect(lock_available?).to eq(true)
  end

  it 'keeps the lock until an outer transaction commits' do
    IncomingMessage.transaction do
      described_class.synchronize(message) { nil }
      expect(lock_available?).to eq(false)
    end
    expect(lock_available?).to eq(true)
  end

  it 'keeps the lock after a savepoint commits, until the outer commit' do
    IncomingMessage.transaction do
      IncomingMessage.transaction(requires_new: true) do
        described_class.synchronize(message) { nil }
      end
      expect(lock_available?).to eq(false)
    end
    expect(lock_available?).to eq(true)
  end

  it 'releases the lock when the outer transaction rolls back' do
    IncomingMessage.transaction do
      IncomingMessage.transaction(requires_new: true) do
        described_class.synchronize(message) { nil }
      end
      expect(lock_available?).to eq(false)
      raise ActiveRecord::Rollback
    end
    expect(lock_available?).to eq(true)
  end

  it 'releases the lock when its savepoint rolls back' do
    IncomingMessage.transaction do
      IncomingMessage.transaction(requires_new: true) do
        described_class.synchronize(message) { nil }
        raise ActiveRecord::Rollback
      end
      expect(lock_available?).to eq(true)
    end
  end

  it 'releases the lock when parsing raises' do
    expect {
      described_class.synchronize(message) { raise IOError, 'parse failed' }
    }.to raise_error(IOError, 'parse failed')
    expect(lock_available?).to eq(true)
  end

  it 'releases the lock when an outer transaction rolls back on an exception' do
    expect {
      IncomingMessage.transaction do
        described_class.synchronize(message) { raise IOError, 'parse failed' }
      end
    }.to raise_error(IOError, 'parse failed')
    expect(lock_available?).to eq(true)
  end

  it 'releases the lock even when an after-commit upload fails' do
    message.foi_attachments.delete_all
    service = ActiveStorage::Blob.services.fetch(:attachments)
    allow(service).to receive(:upload).and_raise(IOError, 'upload failed')

    expect {
      IncomingMessage.transaction { message.parse_raw_email! }
    }.to raise_error(IOError, 'upload failed')
    expect(lock_available?).to eq(true)
  end
end
