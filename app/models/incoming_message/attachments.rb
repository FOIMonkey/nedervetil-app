# Various methods for handling `FoiAttachment` records associated with
# `IncomingMessage` records
module IncomingMessage::Attachments
  extend ActiveSupport::Concern

  UnableToExtractAttachments = Class.new(StandardError)

  included do
    has_many :foi_attachments,
             -> { order(:id) },
             inverse_of: :incoming_message,
             dependent: :destroy,
             autosave: true
  end

  class_methods do
    # And look up by URL part number and display filename to get an attachment
    # TODO: relies on extract_attachments calling
    # MailHandler.ensure_parts_counted
    # The filename here is passed from the URL parameter, so it's the
    # display_filename rather than the real filename.
    def get_attachment_by_url_part_number_and_filename(attachments, found_url_part_number, display_filename)
      attachment_by_part_number = attachments.detect do |a|
        a.url_part_number == found_url_part_number
      end

      filename_matches =
        attachment_by_part_number &&
        attachment_by_part_number.display_filename == display_filename

      if filename_matches
        # Then the filename matches, which is fine:
        attachment_by_part_number
      else
        # Otherwise if the URL part number and filename don't
        # match - this is probably due to a reparsing of the
        # email.  In that case, try to find a unique matching
        # filename from any attachment.
        attachments_by_filename = attachments.select do |a|
          a.display_filename == display_filename
        end

        attachments_by_filename[0] if attachments_by_filename.length == 1
      end
    end

    def get_attachment_by_url_part_number_and_filename!(attachments, found_url_part_number, display_filename)
      attachment = get_attachment_by_url_part_number_and_filename(
        attachments, found_url_part_number, display_filename
      )

      return unless attachment

      # check filename in URL matches that in database (use a censor rule if you
      # want to change a filename)
      if attachment.display_filename != display_filename &&
         attachment.old_display_filename != display_filename
        msg = 'please use same filename as original file has, display: '
        msg += "'#{ attachment.display_filename }' "
        msg += 'old_display: '
        msg += "'#{ attachment.old_display_filename }' "
        msg += 'original: '
        msg += "'#{ display_filename }'"
        raise ActiveRecord::RecordNotFound, msg
      end

      attachment
    end
  end

  # Returns [] when mail cannot be parsed for display; jobs needing a real
  # attachment list must call #parse_raw_email first.
  def get_attachments_for_display # rubocop:disable Naming/AccessorMethodName
    return [] unless parsed_for_display?

    # return what user would consider attachments, i.e. not the main body
    main_part = get_main_body_text_part
    attachments = []
    foi_attachments.each do |attachment|
      attachments << attachment if attachment != main_part
    end
    attachments
  end

  def extract_attachments!
    extract_attachments
    save!
  end

  # Returns text version of attachment text
  def get_attachment_text_full # rubocop:disable Naming/AccessorMethodName
    _get_attachment_text_internal
  end

  def all_attachments_masked_or_erased?
    foi_attachments.not_erased.where(masked_at: nil).none?
  end

  private

  def _get_attachment_text_internal
    # Extract text from each attachment
    get_attachments_for_display.reduce('') do |memo, attachment|
      next memo if Ability.guest.cannot?(:read, attachment)
      next memo if attachment.masking_failed?

      text = attachment.body_to_text

      # Apply default masks too (stored files only carry incoming/admin masks);
      # tracked on :body_to_text since it differs from FoiAttachment#body.
      text = attachment.apply_all_masks(
        text,
        'text/html',
        redacted_attribute: :body_to_text
      )

      memo + text
    end
  end

  def extract_attachments(reading = MailHandler::Reading.of(raw_email.data))
    raw_email_ensure_not_erased!

    # Parts with the same bytes are one attachment: the first one's place,
    # the last one's attributes.
    parts = reading.parts.each_with_object({}) do |part, memo|
      memo[part.hexdigest] = part
    end
    attachment_attributes = parts.transform_values(&:attributes)

    # Defer storage writes until after protection checks pass so an aborted
    # reparse never mutates stored bytes.
    deferred_bodies = {}
    attachments = attachment_attributes.map do |hexdigest, attrs|
      attachment = foi_attachments.find_or_initialize_by(hexdigest: hexdigest)
      assign_parsed_attributes(attachment, attrs, deferred_bodies)
    end

    # Get the main body part from the set of attachments not from the
    # foi_attachments association - some of the total set of foi_attachments may
    # now be obsolete. Sometimes (e.g. when parsing mail from Apple Mail) we can
    # end up with less attachments because the hexdigest of an attachment is
    # identical.
    main_part = get_main_body_text_part(attachments)

    if main_part
      c = reading.count_first_uudecode_count
      blocks = main_text_blocks(reading, main_part)
      attachments += _uudecode_attachments(blocks, c, deferred_bodies)
      normalize_extracted_main_body(main_part, deferred_bodies)
    end

    old_attachments = (foi_attachments - attachments)
    refuse_if_protected!(old_attachments)

    old_attachments.each(&:mark_for_destruction)

    deferred_bodies.each do |attachment, body|
      attachment.body = body
      attachment.clear_rasterized_metadata!
    end
  end

  def refuse_if_protected!(old_attachments)
    protected_old = old_attachments.reject do |a|
      a.prominence == 'requester_only' && !a.erased? && !a.black_masked?
    end
    return unless protected_old.any?

    raise UnableToExtractAttachments,
          'unable to extract attachments due to protected attachments ' \
          "(ID=#{protected_old.map(&:id).join(', ')})"
  end

  def normalize_extracted_main_body(main_part, deferred_bodies)
    return unless deferred_bodies.key?(main_part)

    raw_bytes = deferred_bodies[main_part]
    normalized = normalize_main_body(main_part, raw_bytes,
                                     content_type: main_part.content_type)
    main_part.content_type = 'text/plain'
    main_part.charset = 'UTF-8'
    if main_part.filename.present? && main_part.filename.match?(/\.html?\z/i)
      main_part.filename = main_part.filename.sub(/\.html?\z/i, '.txt')
    end
    deferred_bodies[main_part] = normalized
  rescue AttachmentToText::ConversionFailed
    nil
  end

  # MailHandler::Report stops scanning after MAX_UU_BLOCKS; if main_part wasn't
  # scanned (uuencoded is nil), reject the mail as TooComplex.
  def main_text_blocks(reading, main_part)
    searched = reading.parts.find do |part|
      part.hexdigest == main_part.hexdigest && part.uuencoded
    end
    return searched.uuencoded if searched

    raise MailHandler::TooComplex,
          'as many uuencoded blocks as a mail may hold come before the ' \
          'main text'
  end

  # Returns attachments uuencoded in the main body, numbered after mail parts.
  def _uudecode_attachments(blocks, start_part_number, deferred_bodies)
    blocks.each_with_index.map do |block, index|
      attrs = { body: block.body, filename: block.filename,
                content_type: block.content_type,
                url_part_number: start_part_number + index + 1 }
      attachment = foi_attachments.
                   find_or_initialize_by(hexdigest: block.hexdigest)
      assign_parsed_attributes(attachment, attrs, deferred_bodies)
    end
  end

  def assign_parsed_attributes(attachment, attrs, deferred_bodies)
    if attachment.persisted? &&
       (attachment.erased? || attachment.is_public? ||
        attachment.manual_black_mask?)
      attrs = attrs.except(:body, :filename, :content_type)
    else
      deferred_bodies[attachment] = attrs[:body]
      attrs = attrs.except(:body)
      if attachment.persisted?
        attachment.masked_at = nil
        attachment.masking_failed_at = nil
        attachment.black_masked = false
      end
    end
    attachment.attributes = attrs
    attachment
  end
end
