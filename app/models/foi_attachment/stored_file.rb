# Active Storage file persistence for FoiAttachment.
module FoiAttachment::StoredFile
  extend ActiveSupport::Concern

  def stored_state
    return :erased if erased?
    return :failed if masking_failed?

    masked_at ? :masked : :unmasked
  end

  def store_file!(data, content_type: nil)
    bytes = data.to_s
    self.hexdigest ||= Digest::MD5.hexdigest(bytes)
    self.content_type = content_type if content_type
    ensure_filename!

    if file.attached?
      file_blob.content_type = self.content_type if content_type
      file_blob.filename = filename if filename.present?
      upload_stored(bytes)
    else
      file.attach(io: StringIO.new(bytes), filename: filename,
                  content_type: self.content_type)
    end

    @cached_body = bytes.dup.force_encoding('ASCII-8BIT')
    update_display_size!
  end

  def replace_file!(data, content_type: nil, metadata: nil)
    bytes = data.to_s
    self.hexdigest ||= Digest::MD5.hexdigest(bytes)
    self.content_type = content_type if content_type
    ensure_filename!

    preserved = if metadata.nil?
                  (file_blob&.metadata || {}).except('identified', 'analyzed')
                else
                  metadata
                end

    @cached_body = bytes.dup.force_encoding('ASCII-8BIT')
    update_display_size!

    new_blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(bytes),
      filename: filename,
      content_type: self.content_type,
      service_name: :attachments,
      metadata: preserved,
      identify: false
    )
    file.attach(new_blob)
    save! if persisted?
    incoming_message&.clear_in_database_caches! if main_body_part?
  end

  private

  def store_masked!(data, changed: true)
    with_masking_lock do
      if changed || !file.attached?
        store_file!(data)
      else
        @cached_body = data.to_s.dup.force_encoding('ASCII-8BIT')
      end
      yield if block_given?
    end
  end

  def with_masking_lock
    self.class.transaction do
      row = self.class.lock.where(id: id).pick(:erased_at)
      next false if row.present? || !self.class.exists?(id: id)

      yield
      true
    end
  end

  def upload_stored(data, blob = file_blob)
    blob.upload(StringIO.new(data.to_s), identify: false)
    blob.save
  end
end
