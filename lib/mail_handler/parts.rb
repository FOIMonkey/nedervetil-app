require 'cgi'
require 'digest'
require 'stringio'
require 'mail'
require 'alaveteli_file_types'
require 'normalize_string'
require 'mail_handler/mail_extensions'

# Splits email bodies into parts (MailHandler::Parts) with limits and errors.
# Loads without Rails, settings or DB (only mail, charlock_holmes, marcel);
# callers provide OfficePackage::CompoundFile and AlaveteliSandbox.
module MailHandler
  TooComplex = Class.new(StandardError)

  # Transient or sandbox failure; nothing was read and the read can be retried.
  ReadRefused = Class.new(StandardError)
  MAX_PART_DEPTH = 30
  MAX_PARTS = 1_000
  MAX_UU_BLOCK_BYTES = 25 * 1024 * 1024
  MAX_UU_BLOCKS = 100
  UU_BEGIN = /\Abegin [0-7]{1,4} ([^\r\n]+)\r?\n\z/
  UU_ZERO = /\A[` ]\r?\n\z/
  UU_END = /\Aend\r?\n\z/

  class TNEFParsingError < StandardError
  end

  TNEF_MAX_FILES = 500
  TNEF_MAX_BYTES = 512 * 1024 * 1024

  OUTLOOK_MAX_BYTES = 512 * 1024 * 1024

  # Perl load errors indicate a broken msgconvert install, not bad input.
  PERL_NOT_LOADED = Regexp.union(/Can't locate \S+ in @INC/,
                                 /compilation aborted/,
                                 /Compilation failed in require/)

  # Required Outlook stream; compound files without it (e.g. a .doc named .msg)
  # are not messages and must not be passed to msgconvert.
  OUTLOOK_PROPERTIES = '__properties_version1.0'.freeze

  BLANK = /\A[[:space:]]*\z/

  # Splits an email into attachment parts, expanding RFC 822, Outlook .msg
  # and TNEF messages and extracting uuencoded blocks.
  module Parts
    # Equivalent to Action Mailbox's Mail.from_source without Rails.
    def mail_from_source(source)
      Mail.new(Mail::Utilities.binary_unsafe_to_crlf(source.to_s))
    end

    # As ActiveSupport's blank? is for a string or nil, without ActiveSupport.
    def blank_text?(text)
      return true if text.nil? || text.empty?

      BLANK.match?(text)
    rescue Encoding::CompatibilityError
      Regexp.new(BLANK.source.encode(text.encoding),
                 BLANK.options | Regexp::FIXEDENCODING).match?(text)
    end

    def mail_from_tnef(content)
      main = Mail.new
      tnef_attachments(content).each do |attachment|
        main.add_file(attachment)
      end
      main.ready_to_send!
      main
    end

    # Converts an Outlook message to Mail, or nil to keep unexpanded. Validates
    # OLE sector chains and OUTLOOK_PROPERTIES first so malformed or non-message
    # compound files never reach msgconvert.
    def mail_from_outlook(content)
      streams = OfficePackage::CompoundFile.new(content).streams
      return unless streams.any? do |path, _|
        path == MailHandler::OUTLOOK_PROPERTIES
      end

      source = MailHandler.outlook_as_mime(content)
      return unless source

      mail = mail_from_source(source)
      mail.ready_to_send!
      mail
    rescue OfficePackage::Error
      nil
    end

    def get_within_rfc822_subject(leaf)
      within_rfc822_subject = leaf.within_rfc822_attachment.subject
      return unless within_rfc822_subject

      convert_string_to_utf8(within_rfc822_subject).string
    end

    def get_part_file_name(part)
      part_file_name = part.filename
      part_file_name = part_file_name.nil? ? nil : part_file_name.dup
      if part_file_name
        part_file_name = CGI.unescape(part_file_name)
        part_file_name =
          convert_string_to_utf8(part_file_name, part.charset).string
      end
      part_file_name
    end

    # Decodes part body, falling back to raw bytes on unknown transfer encoding.
    def decoded_part_body(part)
      part.body.decoded
    rescue Mail::UnknownEncodingType
      part.body.raw_source.to_s
    end

    def get_part_body(part)
      decoded = decoded_part_body(part)
      decoded = decoded.dup if decoded.frozen?
      if /^text\//.match?(part.content_type)
        decoded = convert_string_to_utf8_or_binary decoded, part.charset
      end
      decoded
    end

    def get_content_type(part)
      part.content_type ? part.content_type.split(';')[0] : nil
    end

    def get_header_string(header, mail)
      mail.header[header] ? mail.header[header].to_s : nil
    end

    def is_outlook?(part)
      filename = get_part_file_name(part)
      return true if get_content_type(part) == 'application/vnd.ms-outlook'
      if filename &&
         AlaveteliFileTypes.filename_to_mimetype(filename) ==
         'application/vnd.ms-outlook'
        return true
      end

      false
    end

    # Decodes an attached RFC822/Outlook/TNEF message into rfc822_attachment,
    # falling back to text/plain (RFC822) or application/octet-stream on error.
    def decode_attached_part(part, parent_mail, depth = 0, count = { parts: 0 })
      if get_content_type(part) == 'message/rfc822'
        part.rfc822_attachment = mail_from_source(decoded_part_body(part))
        if part.rfc822_attachment.nil?
          # Treat unparseable message/rfc822 parts as plain text.
          part.content_type = 'text/plain'
        end
      elsif is_outlook?(part)
        part.rfc822_attachment = mail_from_outlook(decoded_part_body(part))
        if part.rfc822_attachment.nil?
          part.content_type = 'application/octet-stream'
        end
      elsif get_content_type(part) == 'application/ms-tnef'
        begin
          part.rfc822_attachment = mail_from_tnef(decoded_part_body(part))
          if part.rfc822_attachment.nil?
            part.content_type = 'application/octet-stream'
          end

        rescue TNEFParsingError
          part.rfc822_attachment = nil
          part.content_type = 'application/octet-stream'
        end
      end
      return unless part.rfc822_attachment

      expand_and_normalize_parts(part.rfc822_attachment, parent_mail,
                                 depth + 1, count)
    end

    def expand_and_normalize_parts(part, parent_mail, depth = 0,
                                   count = { parts: 0 })
      raise MailHandler::TooComplex, 'mail nesting limit exceeded' if
        depth > MailHandler::MAX_PART_DEPTH

      count[:parts] += 1
      raise MailHandler::TooComplex, 'mail part limit exceeded' if
        count[:parts] > MailHandler::MAX_PARTS

      if part.multipart?
        Mail::PartsList.new(part.parts.each do |sub_part|
          expand_and_normalize_parts(sub_part, parent_mail, depth + 1, count)
        end)
      else
        normalize_leaf(part, parent_mail, depth, count)
      end
    end

    def normalize_leaf(part, parent_mail, depth, count)
      part_filename = get_part_file_name(part)
      if part.has_charset?
        # save this, because overwriting content_type also resets charset
        original_charset = part.charset
      else
        original_charset = nil
      end
      if get_content_type(part).nil?
        part.content_type = 'application/octet-stream'
      end

      # PDFs often come with this mime type, fix it up for view code
      if get_content_type(part) == 'application/octet-stream'
        part_body = get_part_body(part)
        calc_mime = AlaveteliFileTypes.filename_and_content_to_mimetype(
          part_filename, part_body
        )
        part.content_type = calc_mime if calc_mime != 'application/octet-stream'
      end

      part.content_type = normalise_content_type(get_content_type(part))

      # Reassigning content_type discards any `name` parameter; restore it so
      # the attachment keeps its original filename.
      if !blank_text?(part_filename) && get_part_file_name(part).nil?
        type, subtype = get_content_type(part).split('/', 2)
        part.content_type = [type, subtype, { 'name' => part_filename }]
      end

      decode_attached_part(part, parent_mail, depth, count)
      part.charset = original_charset if original_charset
    end

    def count_parts(part, parent_mail)
      if part.multipart?
        part.parts.each { |p| count_parts(p, parent_mail) }
      elsif part.rfc822_attachment
        count_parts(part.rfc822_attachment, parent_mail)
      else
        parent_mail.count_parts_count += 1
        part.url_part_number = parent_mail.count_parts_count
      end
      parent_mail.count_first_uudecode_count = parent_mail.count_parts_count
    end

    def choose_best_alternative(mail)
      return mail.parts.detect(&:multipart?) if mail.parts.any?(&:multipart?)

      if mail.html_part
        mail.html_part
      elsif mail.text_part
        mail.text_part
      else
        mail.parts.first
      end
    end

    def get_attachment_leaves(mail)
      # TODO: Most of these methods are modifying in place! :(
      expand_and_normalize_parts(mail, mail)
      leaves = _get_attachment_leaves_recursive(mail, nil, mail)
      mail.count_parts_count = 0
      count_parts(mail, mail)
      leaves
    end

    def _get_attachment_leaves_recursive(part, within_rfc822_attachment, parent_mail)
      leaves_found = []
      if part.multipart?
        if part.parts.empty?
          # Missing final MIME boundary leaves message text in part.body;
          # treat the container as a text/plain leaf.
          part.content_type = "text/plain"
          leaves_found += [part]
        elsif part.sub_type == 'alternative'
          best_part = choose_best_alternative(part)
          leaves_found += _get_attachment_leaves_recursive(
            best_part, within_rfc822_attachment, parent_mail
          )
        else
          part.parts.each do |sub_part|
            leaves_found += _get_attachment_leaves_recursive(
              sub_part, within_rfc822_attachment, parent_mail
            )
          end
        end
      elsif part.rfc822_attachment
        leaves_found += _get_attachment_leaves_recursive(
          part.rfc822_attachment, part.rfc822_attachment, parent_mail
        )
      else
        part.within_rfc822_attachment = within_rfc822_attachment
        leaves_found += [part]
      end
      leaves_found
    end

    def same_rfc822_message?(leaf)
      leaf.within_rfc822_attachment == leaf
    rescue Mail::UnknownEncodingType, ArgumentError,
           Encoding::CompatibilityError
      leaf.within_rfc822_attachment.equal?(leaf)
    end

    def extract_attached_message_headers(leaf)
      body = get_part_body(leaf)
      # Prepend selected headers on the first text/plain part of an attached
      # RFC822 message.
      if same_rfc822_message?(leaf) &&
         get_content_type(leaf) == 'text/plain'
        headers = ""
        %w[Date Subject From To Cc].each do |header|
          if (header_value = get_header_string(header,
                                               leaf.within_rfc822_attachment))
            unless blank_text?(header_value)
              headers = headers + header + ": " +
                        convert_string_to_utf8(header_value.to_s).string + "\n"
            end
          end
        end
        # TODO: call _convert_part_body_to_text here, but need to get charset
        # somehow
        # e.g. http://www.whatdotheyknow.com/request/1593/response/3088/attach/4/Freedom%20of%20Information%20request%20-%20car%20oval%20sticker:%20Article%2020,%20Convention%20on%20Road%20Traffic%201949.txt
        body = if body.encoding == Encoding::BINARY
                 headers.b + "\n".b + body
               else
                 headers + "\n" + body
               end
      end
      body
    end

    def get_attachment_attributes(mail)
      get_attachment_leaves(mail).inject([]) do |acc, leaf|
        original_body = body = get_part_body(leaf)

        if leaf.within_rfc822_attachment
          within_rfc822_subject = get_within_rfc822_subject(leaf)
          body = extract_attached_message_headers(leaf)
        end

        acc.push(
          url_part_number: leaf.url_part_number,
          content_type: get_content_type(leaf),
          filename: get_part_file_name(leaf),
          charset: leaf.charset,
          within_rfc822_subject: within_rfc822_subject,
          original_body: original_body,
          body: body,
          hexdigest: Digest::MD5.hexdigest(body)
        )

        acc
      end
    end

    # Ensure bodies have the same line endings and are encoded the same
    def calculate_hexdigest(body)
      Digest::MD5.hexdigest(
        Mail::Utilities.binary_unsafe_to_lf(
          convert_string_to_utf8(
            body.rstrip
          ).string
        )
      )
    end

    def uudecode(text, start_part_number)
      uus = MailHandler.uuencoded_blocks(text)
      uus.map.with_index do |uu, index|
        body = uu.sub(/\Abegin \d+ [^\n]*\n/, '').unpack('u').first
        filename = uu.lines.first.match(MailHandler::UU_BEGIN)[1]
        mime_type = AlaveteliFileTypes.filename_and_content_to_mimetype(
          filename, body
        )
        content_type = MailHandler.normalise_content_type(mime_type)
        hexdigest = Digest::MD5.hexdigest(body)

        {
          body: body,
          filename: filename,
          content_type: content_type,
          hexdigest: hexdigest,
          url_part_number: start_part_number + index + 1
        }
      end
    end

    # Extracts TNEF attachments in a sandbox (ignoring the duplicate TNEF body).
    def tnef_attachments(content)
      limits = { output_files: TNEF_MAX_FILES, output_bytes: TNEF_MAX_BYTES }
      AlaveteliSandbox.job(input: content, input_name: 'winmail.dat',
                           **limits) do |job|
        job.run('tnef', '-K', '-C', job.scratch, '-f', job.input,
                file_size: TNEF_MAX_BYTES)

        # sorted for deterministic behaviour
        attachments = job.files.map do |file|
          { content: job.read(file, max: TNEF_MAX_BYTES), filename: file }
        end
        if attachments.empty?
          raise TNEFParsingError, "tnef produced no attachments"
        end

        attachments
      end
    rescue AlaveteliSandbox::Failed, AlaveteliSandbox::LimitExceeded => e
      # Unreadable TNEF stays one binary attachment.
      raise TNEFParsingError, "tnef failed: #{e.message}"
    rescue AlaveteliSandbox::Refused, AlaveteliSandbox::TimedOut => e
      # Sandbox failure, not bad input: fail the parse so it is retried.
      raise ReadRefused, "tnef could not run: #{e.message}"
    end

    # Converts an Outlook .msg/.oft to MIME via msgconvert, or nil if invalid.
    def outlook_as_mime(content)
      limits = { output_files: 1, output_bytes: OUTLOOK_MAX_BYTES }
      AlaveteliSandbox.job(input: content, input_name: 'message.msg',
                           **limits) do |job|
        job.run('msgconvert', '--outfile', job.scratch('message.eml'),
                job.input, file_size: OUTLOOK_MAX_BYTES)
        job.read('message.eml', max: OUTLOOK_MAX_BYTES)
      end
    rescue AlaveteliSandbox::Failed => e
      # Distinguish a missing/broken msgconvert from an unreadable file so
      # broken installs raise ReadRefused instead of silently skipping .msg.
      unless msgconvert_ran?(e)
        raise ReadRefused, "msgconvert could not run: #{e.message}"
      end

      nil
    rescue AlaveteliSandbox::LimitExceeded
      nil
    rescue AlaveteliSandbox::Refused, AlaveteliSandbox::TimedOut => e
      # Sandbox failure, not bad input: fail the parse so it is retried.
      raise ReadRefused, "msgconvert could not run: #{e.message}"
    end

    def msgconvert_ran?(failure)
      failure.result && !failure.result.stderr.to_s.match?(PERL_NOT_LOADED)
    end

    CONTENT_TYPE_ALIASES = {
      # e.g. http://www.whatdotheyknow.com/request/93/response/250
      'application/excel' => 'application/vnd.ms-excel',
      'application/msexcel' => 'application/vnd.ms-excel',
      'application/x-ms-excel' => 'application/vnd.ms-excel',
      'application/mspowerpoint' => 'application/vnd.ms-powerpoint',
      'application/x-ms-powerpoint' => 'application/vnd.ms-powerpoint',
      'application/msword' => 'application/vnd.ms-word',
      'application/x-ms-word' => 'application/vnd.ms-word',
      'application/x-zip-compressed' => 'application/zip',
      # e.g. http://www.whatdotheyknow.com/request/copy_of_current_swessex_scr_opt#incoming-9928
      'application/acrobat' => 'application/pdf',
      'document/pdf' => 'application/pdf'
    }.freeze

    # A copy, so that a caller changing the string cannot change the table.
    def normalise_content_type(content_type)
      CONTENT_TYPE_ALIASES[content_type]&.dup || content_type
    end

    def uuencoded_ranges(text)
      ranges = []
      start = nil
      zero_line = false
      offset = 0

      text.b.each_line do |line|
        finish = offset + line.bytesize
        if start && finish - start > MAX_UU_BLOCK_BYTES
          start = nil
          zero_line = false
        end

        if start && zero_line && line.match?(UU_END)
          ranges << (start...finish)
          start = nil
          zero_line = false
        elsif line.match?(UU_BEGIN)
          start = offset
          zero_line = false
        elsif start
          zero_line = line.match?(UU_ZERO)
        end

        offset = finish
        break if ranges.size >= MAX_UU_BLOCKS
      end
      ranges
    end

    def uuencoded_blocks(text)
      uuencoded_ranges(text).map { |range| text.byteslice(range) }
    end

    def strip_uuencoded_blocks(text)
      ranges = uuencoded_ranges(text)
      return text.dup if ranges.empty?

      result = text.byteslice(0, 0)
      offset = 0
      ranges.each do |range|
        result << text.byteslice(offset, range.begin - offset) << ' '
        offset = range.end
      end
      result << text.byteslice(offset, text.bytesize - offset)
    end
  end

  include Parts

  extend self
end
