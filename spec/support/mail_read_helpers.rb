module MailReadHelpers
  def watch_mail_reads
    reads = []
    allow(MailHandler::Reading).to receive(:of).
      and_wrap_original do |original, source, **options|
        connection = ActiveRecord::Base.connection
        reads << {
          options: options,
          transactions: connection.open_transactions,
          advisory_locks: connection.select_value(
            "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' " \
            'AND pid = pg_backend_pid()'
          )
        }
        yield if block_given?
        original.call(source, **options)
      end
    reads
  end

  def refuse_mail_reads
    allow(MailHandler::Reading).to receive(:of).
      and_raise(MailHandler::ReadRefused, 'the mail cell is down')
  end

  def allow_mail_reads
    allow(MailHandler::Reading).to receive(:of).and_call_original
  end
end
