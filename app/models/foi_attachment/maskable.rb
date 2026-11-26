# In-place masking of FoiAttachment stored files.
module FoiAttachment::Maskable
  extend ActiveSupport::Concern

  FAULT_NOTES = %w[masking_fault served_after_fault].freeze
  CONVERSION_NOTES = %w[converted_from_content_type
                        converted_from_extension].freeze

  included do
    scope :masked, -> { where.not(masked_at: nil) }
    scope :unmasked, -> { where(masked_at: nil) }
  end

  def masked?
    file.attached? && masked_at.present? && masked_at < Time.zone.now
  end

  def masking_failed?
    masking_failed_at.present?
  end

  attr_reader :masking_error

  def unmasked_parts
    Array(mask_notes['unmasked_parts'])
  end

  def masking_fault
    fault = mask_notes['masking_fault'] or return

    [mask_notes['served_after_fault']&.to_sym, fault]
  end

  # Masks the stored file in place with black rules; never reads RawEmail.
  def mask
    ensure_not_erased!
    current = stored_bytes

    unmasked = []
    @masking_error = nil
    rule_matched = false
    begin
      masked_body, rule_matched = mask_bytes(current, unmasked)
    rescue Regexp::TimeoutError, AlaveteliTextMasker::PDFMaskingError => e
      @masking_error = e
    end

    if @masking_error
      store_fallback(current)
    else
      changed = masked_body.b != current.b
      store_masked!(masked_body, changed: changed) do
        attrs = { masked_at: Time.zone.now, masking_failed_at: nil }
        attrs[:black_masked] = true if rule_matched
        update(attrs)
        remember_mask(unmasked)
      end
      incoming_message&.clear_in_database_caches! if changed && main_body_part?
    end
  end

  def remask_from_email!
    return false unless raw_email&.kept? && !erased?

    raw = original_attributes
    bytes = raw[:body]
    type = raw[:content_type]
    if main_body_part?
      bytes = incoming_message.normalize_main_body(self, bytes,
                                                   content_type: type)
      type = 'text/plain'
    end

    self.black_masked = false
    self.content_type = type if type.present?
    if raw[:filename].present? && !main_body_part?
      self.filename = raw[:filename]
    end
    store_file!(bytes, content_type: type)
    clear_rasterized_metadata!
    clear_conversion_metadata!
    self.masked_at = nil
    self.masking_failed_at = nil
    save!
    mask
    AttachmentManagement::Revision.
      where(foi_attachment_id: id, status: 'applied').
      update_all(status: 'superseded', updated_at: Time.current)
    applied_revisions.reset
    AttachmentManagement::Previews.clear(id)
    incoming_message&.clear_in_database_caches! if main_body_part?
    true
  end

  def manual_black_mask?
    file_blob&.metadata&.dig('manual_black_mask') == true
  end

  def rasterized?
    file_blob&.metadata&.dig('rasterized') == true
  end

  def clear_rasterized_metadata!
    return unless file.attached? && file_blob&.metadata&.key?('rasterized')

    file_blob.update!(metadata: file_blob.metadata.except('rasterized'))
  end

  def clear_conversion_metadata!
    return unless file.attached? && file_blob&.metadata.present?

    remaining = file_blob.metadata.except(*CONVERSION_NOTES)
    return if remaining == file_blob.metadata

    file_blob.update!(metadata: remaining)
  end

  def html_attachment?
    return true if content_type == 'text/html'
    return false if filename.blank?

    [filename, FoiAttachment.display_form(filename)].any? do |name|
      AlaveteliFileTypes.filename_to_mimetype(name) == 'text/html'
    end
  end

  def start_again!
    if manual_black_mask?
      raise Disclosures::Error::Refused,
            _('An admin has redacted this file, so it can’t be restored ' \
              'from the email.')
    end
    return :email_gone unless raw_email&.kept?

    remask_from_email!
    :restored
  end

  def mask_later
    FoiAttachment::MaskJob.perform_later(self)
  end

  def mask_siblings
    return unless incoming_message

    incoming_message.foi_attachments.each do |sibling|
      next if sibling == self
      next if sibling.masked? || sibling.erased?

      FoiAttachment::MaskJob.unlock!(sibling)
      FoiAttachment::MaskJob.perform_now(sibling)
    end
  end

  def masked_default_body
    apply_censor_rules(default_body, content_type,
                       redacted_attribute: :default_body, masked: true)
  rescue AlaveteliTextMasker::PDFMaskingError, Regexp::TimeoutError
    default_body
  end

  private

  def stored_bytes
    unless file.attached?
      raise FoiAttachment::MissingError, "attachment missing (ID=#{id})"
    end

    file.download
  rescue ActiveStorage::FileNotFoundError
    raise FoiAttachment::MissingError,
          "attachment missing from storage (ID=#{id})"
  end

  def mask_bytes(current, unmasked)
    source = if text_type?
               convert_string_to_utf8(current, 'UTF-8').string
             else
               current
             end
    matched = []
    masked = apply_censor_rules(source, content_type,
                                redacted_attribute: :body,
                                masked: true,
                                unmasked: unmasked,
                                matched: matched)
    rule_matched = matched.any?
    final_body = html_attachment? ? sanitise_html(masked) : masked
    [final_body, rule_matched]
  end

  def store_fallback(current)
    fallback = html_attachment? ? sanitise_html(current) : current
    store_masked!(fallback, changed: fallback.b != current.b) do
      record_fault
      remember_fault(@masking_error)
    end
  end

  def record_fault
    update(masked_at: Time.zone.now,
           masking_failed_at: masking_failed_at || Time.zone.now)
  end

  def remember_mask(unmasked)
    return unless file.attached?

    notes = file_blob.metadata.except(*FAULT_NOTES, 'unmasked_parts')
    notes['unmasked_parts'] = unmasked if unmasked.any?
    file_blob.update!(metadata: notes) unless notes == file_blob.metadata
  end

  def remember_fault(fault)
    return unless file.attached?

    what = "#{fault.class}: #{fault.message.lines.first.to_s.strip}".
           truncate(300)
    file_blob.update!(
      metadata: file_blob.metadata.merge('masking_fault' => what,
                                         'served_after_fault' => 'as_it_came')
    )
  end

  def mask_notes
    return {} if erased? || masked_at.blank?
    return {} unless file.attached?

    file_blob.metadata
  end
end
