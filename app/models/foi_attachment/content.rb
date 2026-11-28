# Masked text and source fingerprints shared by readers of reply attachments.
module FoiAttachment::Content
  IMAGE_EXTENSIONS = %w[jpg jpeg png gif svg webp bmp tiff tif ico].freeze

  MAX_DOCUMENTS = 8
  MAX_DOCUMENT_BYTES = 10 * 1024 * 1024
  EXTRACTION_SECONDS = 60

  module_function

  def image_filename?(name)
    extension = File.extname(name.to_s).delete_prefix('.').downcase
    IMAGE_EXTENSIONS.include?(extension)
  end

  def fingerprint(part)
    blob = part.file.attached? ? part.file.blob : nil
    [part.updated_at&.to_f, part.masked_at&.to_f,
     part.erased_at&.to_f, part.masking_failed_at&.to_f, part.hexdigest,
     part.prominence, blob&.id, blob&.checksum]
  end

  # Re-apply default masks since stored files only carry inbound censor rules.
  def document_text(part)
    part.apply_all_masks(part.body_to_text.to_s,
                         'text/html',
                         redacted_attribute: :body_to_text)
  rescue StandardError => e
    Rails.logger.warn('request_outcome_document_text_failed ' \
                      "attachment_id=#{part&.id} #{e.class}")
    nil
  end

  # Strip emails and apply censor rules to the outgoing request before masking.
  def asked(request, outgoing)
    request.apply_all_masks(outgoing.get_text_for_indexing(false).to_s,
                            'text/plain')
  end
end
