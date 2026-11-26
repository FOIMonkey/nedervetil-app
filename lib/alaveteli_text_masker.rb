require 'config_helper'

# Applies default personal-data masks (email addresses, mobile numbers, login
# links) and CensorRules across PDFs, text and binary files while skipping
# images, archives and zip-based documents.
module AlaveteliTextMasker
  include ConfigHelper

  extend self

  DEFAULT_TEXT_MASKS = {
    email_address: {
      to_replace: MySociety::Validate.email_find_regexp,
      replacement: "[#{_('email address')}]"
    },
    mobile_number: {
      to_replace: /(Mobile|Mob)([\s\/]*(Fax|Tel))*\s*:?[\s\d]*\d/,
      replacement: "[#{_('mobile number')}]"
    },
    login_link: {
      to_replace: /https?:\/\/#{AlaveteliConfiguration.domain}\/c\/[^\s]+/,
      replacement: "[#{_('{{site_name}} login link', site_name: site_name)}]"
    }
  }.with_indifferent_access.deep_symbolize_keys.freeze

  # Raised when a PDF cannot be masked; faulted files are marked for admins
  # and never published (see FoiAttachment::Maskable#masking_outcome).
  PDFMaskingError = Class.new(StandardError)

  # Reasons recorded in options[:unmasked] when masking cannot open a file.
  UNMASKED_PDF = 'the PDF needs a password, so masking could not open it'.freeze
  UNMASKED_ZIP = 'the file is an archive (zip, 7-Zip, RAR, gzip), or a ' \
                 'document stored as a zip (Office, ODF), which masking ' \
                 'cannot open yet'.freeze

  # Byte-pass skip reason; identifies rule by id so secret text is not exposed.
  UNMASKED_RULE = 'anything censor rule %<id>s matches: its pattern only ' \
                  'works on text, and this kind of file is masked as ' \
                  'bytes'.freeze

  # Slice size for BytePass#strip_nul to avoid monopolizing the GVL.
  NUL_STRIP_SLICE = 1024 * 1024

  # Rule scopes that trigger PDF OCR (omitting global/body rules for speed).
  OCR_RULE_TYPES = %w[InfoRequest User].freeze

  # Zip containers bypass BytePass (compressed content is unreachable and byte
  # replacement can corrupt stored parts, upstream #3233; see doc/FORK.md).
  # Matched by MIME prefix or zip magic so legacy OLE (.doc/.xls/.ppt) and
  # uncompressed ODF -flat-xml variants stay byte-masked.
  ZIP_CONTAINER_PREFIXES = %w[
    application/vnd.openxmlformats-officedocument.
    application/vnd.ms-word.
    application/vnd.ms-excel.
    application/vnd.ms-powerpoint.
    application/vnd.sun.xml.
  ].freeze

  # Images are never masked, by design, so they go as they came, unmarked.
  DO_NOT_BINARY_MASK = %w[
    image/tiff image/gif image/jpeg image/png image/bmp
  ].freeze

  TEXT_MASK = ['text/css',
               'text/csv',
               'text/html',
               'text/plain',
               'text/rfc822-headers',
               'text/rtf',
               'text/tab-separated-values',
               'text/x-c',
               'text/x-diff',
               'text/x-fortran',
               'text/x-mail',
               'text/xml',
               'text/x-pascal',
               'text/x-vcard'].freeze

  # Replaces all email addresses in (possibly binary) data
  # Also applies custom masks and censor items
  #
  # options[:unmasked] collects skipped parts for admins (excluding images).
  # options[:default_masks] = false omits default masks on incoming files.
  def apply_masks(text, content_type, options = {})
    return text if text.nil?

    pass_for(content_type, text).new(self, content_type, options).apply(text)
  end

  def archive?(content_type, body)
    type = content_type.to_s.downcase
    return true if type == 'application/zip'
    return true if ZIP_CONTAINER_PREFIXES.any? { |p| type.start_with?(p) }
    if type.start_with?('application/vnd.oasis.opendocument.') &&
       !type.end_with?('-flat-xml')
      return true
    end

    head = body.to_s.byteslice(0, 64).to_s.b
    archive_signatures.any? { |re| head.match?(re) }
  end

  # Archive magic bytes from PDFRedactor::FinalScan::CONTAINERS so both agree;
  # loaded lazily because this module loads before PDFRedactor.
  def archive_signatures
    @archive_signatures ||=
      PDFRedactor::FinalScan::CONTAINERS.filter_map do |re, _, kind|
        Regexp.new("\\A(?:#{re.source})", re.options) if kind == :archive
      end.freeze
  end

  def masks
    @masks ||= DEFAULT_TEXT_MASKS.deep_dup
  end

  def add_mask(name, pattern:, replacement:)
    name = name.to_sym
    raise ArgumentError, "Mask already exists with name :#{name}" if
      masks.key?(name)

    masks[name] = { to_replace: pattern, replacement: replacement }
  end

  def remove_mask(name)
    raise ArgumentError, "No mask found with name :#{name}" unless
      masks.delete(name)
  end

  def replace_mask(name, pattern: nil, replacement: nil)
    raise ArgumentError, "No mask found with name :#{name}" unless
      masks.key?(name)

    masks[name][:to_replace] = pattern if pattern
    masks[name][:replacement] = replacement if replacement
  end

  def reset_masks!
    @masks = nil
  end

  # Builds PDFRedactor rules for verification (Disclosures::TextCopy).
  def pdf_rules(censor_rules, options = {})
    PDFPass.new(self, 'application/pdf', options).rules(censor_rules)
  end

  private

  # See if content type is one that we mask - things like zip files and
  # images may get broken if we try to. We err on the side of masking too
  # much, as many unknown types will really be text.
  def pass_for(content_type, text)
    # Special cases for some content types
    case content_type
    when 'application/pdf' then PDFPass
    when *TEXT_MASK then TextPass
    when *DO_NOT_BINARY_MASK then NeverMasked
    else
      archive?(content_type, text) ? ArchivePass : BytePass
    end
  end
end
