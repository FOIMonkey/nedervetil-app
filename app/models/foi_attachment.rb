# == Schema Information
#
# Table name: foi_attachments
#
#  id                    :integer          not null, primary key
#  content_type          :text
#  filename              :text
#  charset               :text
#  display_size          :text
#  url_part_number       :integer
#  within_rfc822_subject :text
#  incoming_message_id   :integer
#  hexdigest             :string(32)
#  created_at            :datetime
#  updated_at            :datetime
#  prominence            :string           default("requester_only"), not null
#  prominence_reason     :text
#  masked_at             :datetime
#  erased_at             :datetime
#  masking_failed_at     :datetime
#  black_masked          :boolean          default(FALSE), not null
#

# Copyright (c) 2007 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

require 'digest'

# A file extracted from an IncomingMessage and stored through Active Storage.
class FoiAttachment < ApplicationRecord
  include Rails.application.routes.url_helpers
  include LinkToHelper

  include MessageProminence

  def self.prominence_states
    %w(public requester_only hidden)
  end

  def is_public?
    prominence == 'public'
  end

  include ContentType
  include Erasable
  include Eventable
  include HTMLSanitising
  include Maskable
  include MaskedByRequest
  include Prominence
  include StoredFile

  MissingError = Class.new(StandardError)

  belongs_to :incoming_message, inverse_of: :foi_attachments, optional: true
  has_one :raw_email, through: :incoming_message, source: :raw_email
  has_one :info_request, through: :incoming_message, source: :info_request
  has_one :user, through: :info_request
  has_one :disclosure_document, class_name: 'Disclosures::Document',
                                inverse_of: :foi_attachment
  has_many :applied_revisions,
           -> { where(status: 'applied').order(applied_at: :desc, id: :desc) },
           class_name: 'AttachmentManagement::Revision',
           inverse_of: :foi_attachment

  has_one_attached :file, service: :attachments

  validates_presence_of :filename
  validates_presence_of :display_size

  before_validation :ensure_filename!, only: [:filename]
  after_update :invalidate_attention_prediction

  scope :binary, -> { where.not(content_type: AlaveteliTextMasker::TEXT_MASK) }

  delegate :expire, to: :info_request
  delegate :metadata, to: :file_blob, allow_nil: true

  admin_columns exclude: %i[url_part_number within_rfc822_subject hexdigest],
                include: %i[redacted_filename display_filename metadata]

  BODY_MAX_TRIES = 3
  BODY_MAX_DELAY = 5

  def delete_cached_file!
    @cached_body = nil
    file.purge_later if file.attached?
  end

  def reload(*)
    @cached_body = nil
    super
  end

  def body=(data)
    store_file!(data)
  end

  def body
    return @cached_body if @cached_body

    ensure_not_erased!

    return file.download if masked?

    if persisted?
      FoiAttachment::MaskJob.unlock!(self)
      FoiAttachment::MaskJob.perform_now(self)
      return body_after_masking unless destroyed?
    end

    file.download if file.attached?
  end

  # body as UTF-8 text, with scrubbing of invalid chars if needed
  def body_as_text
    ensure_not_erased!
    convert_string_to_utf8(body, 'UTF-8')
  end

  # for text types, the scrubbed UTF-8 text. For all other types, the
  # raw binary
  def default_body
    ensure_not_erased!
    text_type? ? body_as_text.string : body
  end

  # return the body as it is in the raw email, unmasked without censor rules
  # applied
  def unmasked_body
    ensure_not_erased!
    original_attributes[:body]
  end

  def main_body_part?
    incoming_message.present? &&
      self == incoming_message.get_main_body_text_part
  end

  # Returns extra note for delivery-status parts, or nil on ReadRefused.
  def extra_note
    return unless content_type == 'message/delivery-status'

    dsn = DeliveryStatusNotification.new(body)
    return unless dsn.status && dsn.message

    "DSN: #{dsn.status} #{dsn.message}"
  rescue MailHandler::ReadRefused
    nil
  end

  # Called by controller so old filenames still work
  def old_display_filename
    filename = self.filename

    # Convert weird spaces (e.g. \n) to normal ones
    filename = filename.gsub(/\s/, " ")
    # Remove slashes, they mess with URLs
    filename.tr('/', "-")
  end

  def redacted_filename
    return filename unless info_request

    apply_censor_rules(filename, 'text/plain', redacted_attribute: :filename)
  end

  # TODO: changing this will break existing URLs, so have a care - maybe
  # make another old_display_filename see above
  def display_filename
    self.class.display_form(redacted_filename)
  end

  # A filename as it's written in an attachment's URL.
  def self.display_form(filename)
    # Sometimes filenames have e.g. %20 in - no point butchering that
    # (without unescaping it, this would remove the % and leave 20s in there)
    filename = CGI.unescape(filename)
    # Remove weird spaces
    filename = filename.gsub(/\s+/, " ")
    # Remove non-alphabetic characters
    filename = filename.gsub(/[^A-Za-z0-9.]/, " ")
    # Remove spaces near dots
    filename = filename.gsub(/\s*\.\s*/, ".")
    # Compress adjacent spaces down to a single one
    filename = filename.gsub(/\s+/, " ")
    # Strip leading/trailing whitespace
    filename.strip
  end

  def ensure_filename!
    return unless filename.blank?

    calc_ext = AlaveteliFileTypes.mimetype_to_extension(content_type)
    calc_ext = "bin" unless calc_ext
    if !within_rfc822_subject.nil?
      computed = within_rfc822_subject + "." + calc_ext
    else
      computed = "attachment." + calc_ext
    end
    self.filename = computed
  end

  def filename=(filename)
    filename.try(:tr!, "\0\r\n", '')
    calc_ext = AlaveteliFileTypes.mimetype_to_extension(content_type)
    # Put right extension on if missing
    if !filename.nil? && calc_ext &&
       !filename.match?(/\.#{Regexp.escape(calc_ext)}\z/i)
      computed = filename + "." + calc_ext
    else
      computed = filename
    end
    write_attribute('filename', computed)
  end

  # Size to show next to the download link for the attachment
  def update_display_size!
    s = body.size

    if s > 1024 * 1024
      self.display_size = format("%.1f", s.to_f / 1024 / 1024) + 'M'
    else
      self.display_size = (s / 1024).to_s + 'K'
    end
  end

  def body_to_text
    ensure_not_erased!
    AttachmentToText.new(self).to_text
  end

  def storage_key
    file.blob.key if file&.attached?
  end

  def original_attributes
    mail_attributes.slice(:body, :content_type, :filename)
  end

  private

  def invalidate_attention_prediction
    return unless saved_change_to_prominence? || saved_change_to_erased_at?

    IncomingAttention::Prediction.invalidate_message(
      incoming_message_id, 'attachment_visibility_changed'
    )
  end

  def mail_attributes
    unless raw_email&.kept?
      raise RawEmail::Erasable::ErasedError,
            "email is no longer kept (ID=#{raw_email&.id})"
    end

    MailHandler::Reading.page_seconds_left!

    found = MailHandler::Reading.of(raw_email.data, part: hexdigest).
            part_with(hexdigest)
    return found.attributes if found

    begin
      attributes = MailHandler::Reading.of(
        raw_email.data, stored: file.download
      ).matched if file.attached?
    rescue ActiveStorage::FileNotFoundError
      raise MissingError, "attachment missing from storage (ID=#{id})"
    end

    unless attributes
      raise MissingError, "attachment missing in raw email (ID=#{id})"
    end

    update(hexdigest: attributes[:hexdigest])
    attributes
  end

  def body_after_masking
    return @cached_body if @cached_body
    return file.download if masked? && file_blob.service.exist?(file_blob.key)

    raise MissingError, "attachment still missing after masking (ID=#{id})"
  end
end
