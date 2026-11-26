# Serializes parsing through Active Storage's after-commit uploads. A row lock
# ends at the database commit, before those uploads have finished.
class IncomingMessage::ParsingLock
  # IMPR; PostgreSQL keeps two-argument lock keys separate from bigint keys.
  NAMESPACE = 0x494D5052

  def self.synchronize(message)
    message.class.connection_pool.with_connection do |connection|
      lock = new(connection)
      lock.acquire(message.id) if message.persisted?
      begin
        yield lock
      ensure
        if connection.transaction_open?
          # A caller's outer transaction owns the pending uploads. Register
          # after the attachment records, so they finish before we unlock.
          connection.add_transaction_record(lock)
        else
          lock.release
        end
      end
    end
  end

  def initialize(connection)
    @connection = connection
  end

  def acquire(message_id)
    return if @key

    key = "#{NAMESPACE}, #{Integer(message_id)}"
    @connection.execute("SELECT pg_advisory_lock(#{key})")
    @key = key
  end

  def release
    return if @key.nil? || @released

    @connection.execute("SELECT pg_advisory_unlock(#{@key})")
    @released = true
  end

  # Transaction records are finalized even when an earlier record's upload
  # callback raises. Ordinary after_commit callbacks would be skipped then,
  # leaking a session lock into the connection pool.
  def trigger_transactional_callbacks?
    false
  end

  def before_committed!; end

  def committed!(**)
    release
  end

  def rolledback!(**)
    release
  end
end
