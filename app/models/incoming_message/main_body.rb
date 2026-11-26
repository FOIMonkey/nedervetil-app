# Main body text handling and display caching for IncomingMessage.
module IncomingMessage::MainBody
  extend ActiveSupport::Concern

  NotStored = Class.new(StandardError)

  def normalize_main_body(part, raw_bytes, content_type: part.content_type)
    converted = convert_string_to_utf8(raw_bytes.to_s, 'UTF-8')
    text = converted.string

    if content_type == 'text/html'
      text = EmailTables.html_to_text(text) do |html|
        AttachmentToText.from_part(part, html).to_text
      end
    end

    text = MailHandler.strip_uuencoded_blocks(text)
    if converted.scrubbed?
      text += _("\n\n[ {{site_name}} note: The above text was badly " \
                'encoded, and has had strange characters removed. ]',
                site_name: site_name)
    end
    EmailTables.squeeze_spaces(text.gsub(/\r\n/, "\n")).delete("\0")
  rescue ArgumentError => e
    raise unless e.message.end_with?('limit exceeded')

    unbuildable_main_body_note
  end

  # Returns body text from main text part of email, converted to UTF-8, with
  # uudecode removed, emails and privacy sensitive things remove, censored, and
  # folded to remove excess quoted text (marked with FOLDED_QUOTED_SECTION)
  # TODO: returns a .dup of the text, so calling functions can in place modify
  # it
  def get_main_body_text_folded # rubocop:disable Naming/AccessorMethodName
    _cache_main_body_text if cached_main_body_text_folded.nil?
    cached_main_body_text_folded
  end

  def get_main_body_text_unfolded # rubocop:disable Naming/AccessorMethodName
    _cache_main_body_text if cached_main_body_text_unfolded.nil?
    cached_main_body_text_unfolded
  end

  # Like get_main_body_text_*, but raises MailHandler::ReadRefused instead of
  # returning the placeholder note so jobs/exports retry rather than store it.
  def main_body_text!(folded: false)
    text = folded ? get_main_body_text_folded : get_main_body_text_unfolded
    if main_body_unread?
      raise MailHandler::ReadRefused, "main body text not read (ID=#{id})"
    end

    text
  end

  # Parses and persists main body text; raises ReadRefused or NotStored when a
  # transient error prevents caching.
  def store_main_body_text!
    main_body_text!(folded: true)
    return if self.class.where(id: id).
                where.not(cached_main_body_text_folded: nil).exists?

    raise NotStored, "main body text not stored (ID=#{id})"
  end

  # True when the last main-body read returned a ReadRefused placeholder note.
  def main_body_unread?
    @main_body_unread == true
  end

  # Returns body text from main text part of email, converted to UTF-8
  # TODO: This could be a private method – it is only called by IncomingMessage
  # and is directly tested.
  def get_main_body_text_internal # rubocop:disable Naming/AccessorMethodName
    retried = false

    begin
      unless parsed_for_display?
        return '' if raw_email.erased_at?

        raise MailHandler::ReadRefused, "mail not read yet (ID=#{id})"
      end

      main_part = get_main_body_text_part
      _convert_part_body_to_text(main_part)
    rescue FoiAttachment::MissingError
      # occasionally the main body part gets rebuilt while being masked, we
      # should be able to just retry to get the new main body part instance
      # from the db. A part whose file is gone for good stays missing.
      raise if retried

      retried = true
      retry
    end

  rescue FoiAttachment::ErasedError
    ''
  end

  # Returns part which contains main body text, or nil if there isn't one,
  # from a set of foi_attachments. If the leaves parameter is empty or not
  # supplied, uses its own foi_attachments.
  def get_main_body_text_part(leaves = [])
    leaves = foi_attachments if leaves.empty?

    # Find first part which is text/plain or text/html
    # (We have to include HTML, as increasingly there are mail clients that
    # include no text alternative for the main part, and we don't want to
    # instead use the first text attachment
    # e.g. http://www.whatdotheyknow.com/request/list_of_public_authorties)
    leaves.each do |p|
      if (p.content_type == 'text/plain') || (p.content_type == 'text/html')
        return p
      end
    end

    # Otherwise first part which is any sort of text
    leaves.each do |p|
      return p if /^text/.match?(p.content_type)
    end

    # ... or if none, consider first part
    p = leaves[0]
    # if it is a known type then don't use it, return no body (nil)
    if !p.nil? && AlaveteliFileTypes.mimetype_to_extension(p.content_type)
      # this is guess of case where there are only attachments, no body text eg:
      # http://www.whatdotheyknow.com/request/cost_benefit_analysis_for_real_n
      return nil
    end

    # otherwise return it assuming it is text (sometimes you get things
    # like binary/octet-stream, or the like, which are really text - TODO: if
    # you find an example, put URL here - perhaps we should be always returning
    # nil in this case)
    p
  end

  # Returns body text as HTML with quotes flattened, and emails removed.
  def get_body_for_html_display(collapse_quoted_sections = true)
    # Find the body text and remove emails for privacy/anti-spam reasons
    text = get_main_body_text_unfolded
    folded_quoted_text = get_main_body_text_folded

    # Remove quoted sections, adding HTML. TODO: The FOLDED_QUOTED_SECTION is
    # a nasty hack so we can escape other HTML before adding the unfold
    # links, without escaping them. Rather than using some proper parser
    # making a tree structure (I don't know of one that is to hand, that
    # works well in this kind of situation, such as with regexps).
    text = folded_quoted_text if collapse_quoted_sections
    text = MySociety::Format.simplify_angle_bracketed_urls(text)
    text = CGI.escapeHTML(text)
    text = MySociety::Format.make_clickable(text, contract: 1)

    if collapse_quoted_sections
      text =
        text.gsub(/(\s*FOLDED_QUOTED_SECTION\s*)+/m, "FOLDED_QUOTED_SECTION")
      text.strip!

      # if there is nothing but quoted stuff, then show the subject
      if text == "FOLDED_QUOTED_SECTION"
        text = "[Subject only] " + CGI.escapeHTML(safe_subject || '') + text
      end

      # and display link for quoted stuff
      link = <<~HTML
      <span class="unfold_link">
        <a href="?unfold=1#incoming-#{id}">#{_('show quoted sections')}</a>
      </span>
      HTML

      text = text.gsub(/FOLDED_QUOTED_SECTION/, "\n\n" + link + "\n\n")
    elsif folded_quoted_text.include?('FOLDED_QUOTED_SECTION')
      link = <<~HTML
      <span class="unfold_link">
        <a href="?#incoming-#{id}">#{_('hide quoted sections')}</a>
      </span>
      HTML

      text = text + "\n\n" + link
    end
    text.strip!

    text = EmailTables.format(text) do |body|
      ActionController::Base.helpers.simple_format(body)
    end
    # rubocop:disable Rails/OutputSafety -- the email's text was escaped above (CGI.escapeHTML) before links, the fold link and table boxes were added
    text.html_safe
    # rubocop:enable Rails/OutputSafety
  end

  # TODO: This could be a private method – it is only called by IncomingMessage
  # and is directly tested.
  # Every mask, the default ones too: what guests may read gets them.
  def get_body_for_indexing # rubocop:disable Naming/AccessorMethodName
    return '' if Ability.guest.cannot?(:read, get_main_body_text_part)

    apply_all_masks(get_body_for_quoting, 'text/html',
                    redacted_attribute: :body)
  rescue FoiAttachment::MissingError
    ''
  end

  # Returns text of email for using in quoted section when replying
  def get_body_for_quoting # rubocop:disable Naming/AccessorMethodName
    # Get the body text with emails and quoted sections removed
    text = get_main_body_text_folded.dup
    text.gsub!("FOLDED_QUOTED_SECTION", " ")
    text.strip!
    raise "internal error" if text.nil?

    text
  end

  private

  def _cache_main_body_text
    Current.without_memo { build_main_body_text }
  rescue ArgumentError, RuntimeError, Regexp::TimeoutError, TypeError,
         AttachmentToText::ConversionFailed, MailHandler::ReadRefused,
         FoiAttachment::MissingError => e
    raise unless main_body_unbuildable?(e)

    Rails.logger.warn("IncomingMessage #{id}: main body not built (#{e.class})")
    note = unbuildable_main_body_note
    self.cached_main_body_text_unfolded = note
    self.cached_main_body_text_folded = note
    @main_body_unread = e.is_a?(MailHandler::ReadRefused)
    if transient_main_body_error?(e)
      clear_attribute_changes(%i[cached_main_body_text_unfolded
                                 cached_main_body_text_folded])
    else
      save!
    end
  end

  def unbuildable_main_body_note
    _(
      '[ {{site_name}} note: We were not able to process this message. ]',
      site_name: site_name
    )
  end

  def transient_main_body_error?(error)
    error.is_a?(TypeError) ||
      error.is_a?(AttachmentToText::ConversionFailed) ||
      error.is_a?(MailHandler::ReadRefused) ||
      error.is_a?(FoiAttachment::MissingError)
  end

  def main_body_unbuildable?(error)
    case error
    when Regexp::TimeoutError, TypeError, AttachmentToText::ConversionFailed,
         MailHandler::ReadRefused, FoiAttachment::MissingError then true
    when ArgumentError then error.message.end_with?('limit exceeded')
    else
      error.instance_of?(RuntimeError) &&
        error.message.start_with?('main body text more than 1 MB')
    end
  end

  def build_main_body_text
    text = get_main_body_text_internal
    text = MailHandler.strip_uuencoded_blocks(text)

    raise 'main body text more than 1 MB' if text.size > 1_000_000

    folded_quoted_text = remove_lotus_quoting(text, 'FOLDED_QUOTED_SECTION')
    folded_quoted_text =
      IncomingMessage.
      remove_quoted_sections(folded_quoted_text, 'FOLDED_QUOTED_SECTION')

    self.cached_main_body_text_unfolded = text.delete("\0")
    self.cached_main_body_text_folded = folded_quoted_text.delete("\0")
    save!
  end

  # Given a main text part, converts it to text
  def _convert_part_body_to_text(part)
    if part.nil?
      text = "[ Email has no body, please see attachments ]"
    else
      # whatever kind of attachment it is, get the UTF-8 encoded text
      text = part.body_as_text.string

      if part.content_type == 'text/html'
        # e.g. http://www.whatdotheyknow.com/request/35/response/177
        # TODO: This is a bit of a hack as it is calling a
        # convert to text routine.  Could instead call a
        # sanitize HTML one.
        text = EmailTables.html_to_text(text) do |html|
          AttachmentToText.from_part(part, html).to_text
        end
      end
    end

    # Add an annotation if the text had to be scrubbed
    if part && part.body_as_text.scrubbed?
      text += _("\n\n[ {{site_name}} note: The above text was badly " \
                "encoded, and has had strange characters removed. ]",
                site_name: site_name)
    end
    # Fix DOS style linefeeds to Unix style ones (or other later regexps won't
    # work)
    text = text.gsub(/\r\n/, "\n")

    # Compress extra spaces down to save space, and to stop regular expressions
    # breaking in strange extreme cases. e.g. for
    # http://www.whatdotheyknow.com/request/spending_on_consultants
    EmailTables.squeeze_spaces(text)
  end
end
