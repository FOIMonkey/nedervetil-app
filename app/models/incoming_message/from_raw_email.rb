# Handle the parsing and caching of the associated RawEmail
module IncomingMessage::FromRawEmail
  extend ActiveSupport::Concern

  included do
    belongs_to :raw_email, inverse_of: :incoming_message, dependent: :destroy

    scope :unparsed, -> { where(last_parsed: nil) }

    delegate :message_id, to: :raw_email

    cache_from_raw_email :subject, :sent_at,
                         :from_name, :from_email, :from_email_domain,
                         :valid_to_reply_to
  end

  class_methods do
    def cache_from_raw_email(*attrs)
      attrs.each { |attr| cache_attribute_from_raw_email(attr) }
    end

    def cache_attribute_from_raw_email(attr)
      define_method(attr) do
        store_header_values! unless header_values_stored?
        super()
      end
    end
  end

  # Header values are stored on receipt so reads avoid parsing parts; sent_at
  # is always populated and acts as the sentinel.
  def header_values_stored?
    !self[:sent_at].nil?
  end

  # Best-effort on receipt: savepoint prevents header errors (e.g. null bytes)
  # from aborting the surrounding mail-receipt transaction.
  def store_header_values_on_receipt
    transaction(requires_new: true) { update!(header_values) }
  rescue StandardError => e
    restore_attributes
    Rails.logger.warn("IncomingMessage #{id}: header values not stored at " \
                      "receipt (#{e.class})")
  end

  def store_header_values!
    raise "Incoming message id=#{id} has no raw_email" if raw_email.nil?

    raw_email_ensure_not_erased!

    assign_attributes(header_values)
    save! if persisted?
  end

  # Parses once if unparsed; raises MailHandler::ReadRefused for job retries.
  def parse_raw_email
    raise "Incoming message id=#{id} has no raw_email" if raw_email.nil?

    parse_raw_email!(once: true) if last_parsed.nil?
  end

  # Like #parse_raw_email, returning false if erased before first parse.
  def parse_raw_email_if_there
    parse_raw_email
    true
  rescue RawEmail::Erasable::ErasedError
    false
  end

  # Parses for page display without failing on ReadRefused or erasure.
  # Memoizes refusal per instance so repeated display checks don't re-wait
  # on the mail cell.
  def parsed_for_display?
    return false if @shown_unread

    parse_raw_email
    true
  rescue MailHandler::ReadRefused, RawEmail::Erasable::ErasedError => e
    @shown_unread = true
    Rails.logger.warn("IncomingMessage #{id}: shown unread (#{e.message})")
    false
  end

  # Reads mail outside the lock (mail-cell waits can be long), then re-checks
  # erasure and last_parsed under ParsingLock + row lock. With once: true,
  # skips storing if another process parsed first.
  def parse_raw_email!(once: false)
    raise "Incoming message id=#{id} has no raw_email" if raw_email.nil?

    raw_email_ensure_not_erased!

    reading = read_mail unless once && parsed_already?
    checking_documents_after do
      stored = store_parse(reading, once: once)
      stored = store_parse(read_mail, once: once) if stored == :unread
      raw_email.mark_read! if stored && raw_email.persisted?
      stored
    end
  end

  def read_again!
    parse_raw_email!(once: false)
    foi_attachments.reload.not_erased.each do |attachment|
      next if attachment.is_public? || attachment.manual_black_mask?

      attachment.update_column(:masked_at, nil)
      FoiAttachment::MaskJob.perform_now(attachment)
    end
    clear_in_database_caches!
  end

  private

  def checking_documents_after
    yield
  ensure
    begin
      Disclosures::SpreadsheetHold.check_later(self)
    rescue StandardError => e
      Rails.logger.warn("IncomingMessage #{id}: spreadsheet check failed " \
                        "(#{e.class})")
    end
  end

  def store_parse(reading, once:)
    IncomingMessage::ParsingLock.synchronize(self) do |parsing_lock|
      ActiveRecord::Base.transaction do
        # Locking a fresh copy avoids reloading self mid-parse. The parsing
        # lock also covers file uploads after this row lock is released.
        locked = self.class.lock.find(id) if persisted?
        next take_parsed_attributes(locked) if once && locked&.last_parsed
        next :unread unless reading

        raw_email_still_there!
        if reading.is_a?(MailHandler::TooComplex)
          hold_unprocessed(reading)
        else
          extract_or_hold(reading)
        end
        self.last_parsed = Time.zone.now
        result = save!
        # A newly saved message can be seen by another parser after commit.
        parsing_lock.acquire(id)
        result
      end
    end
  end

  # Main-text uuencode limits can trigger TooComplex mid-extraction; drop parts.
  def extract_or_hold(reading)
    extract_attachments(reading)
  rescue MailHandler::TooComplex => e
    foi_attachments.reset
    hold_unprocessed(e)
  end

  def read_mail
    # Before the email is fetched: a page with no reads left fetches none.
    MailHandler::Reading.page_seconds_left!
    MailHandler::Reading.of(raw_email.data)
  rescue MailHandler::TooComplex => e
    e
  end

  def parsed_already?
    persisted? && self.class.where(id: id).where.not(last_parsed: nil).exists?
  end

  # Guard against erasure racing with the unlocked read_mail call.
  def raw_email_still_there!
    return unless raw_email.persisted?
    return unless RawEmail.where(id: raw_email.id).
                  where.not(erased_at: nil).exists?

    raise RawEmail::Erasable::ErasedError,
          "email has been erased (ID=#{raw_email.id})"
  end

  def header_values
    { sent_at: raw_email.date || created_at,
      subject: raw_email.subject,
      from_name: raw_email.from_name,
      from_email: raw_email.from_email || '',
      from_email_domain: raw_email.from_email_domain || '',
      valid_to_reply_to: raw_email.valid_to_reply_to? }
  end

  # Hides over-limit mail while still marking it parsed to prevent retry loops.
  def hold_unprocessed(error)
    Rails.logger.warn("IncomingMessage #{id}: mail not processed " \
                      "(#{error.message})")
    return if prominence == 'hidden'

    was = { old_prominence: prominence,
            old_prominence_reason: prominence_reason }
    self.prominence = 'hidden'
    self.prominence_reason = _(
      'We could not process this message. Please contact us.'
    )
    info_request.log_event(
      'edit_incoming',
      was.merge(incoming_message_id: id,
                editor: User.internal_admin_user,
                prominence: prominence,
                prominence_reason: prominence_reason,
                reason: "Mail not processed: #{error.message}")
    )
  end

  def take_parsed_attributes(parsed)
    names = %w[sent_at subject from_name from_email from_email_domain
               valid_to_reply_to last_parsed]
    names.each { |name| self[name] = parsed[name] }
    clear_attribute_changes(names)
    foi_attachments.reset
  end
end
