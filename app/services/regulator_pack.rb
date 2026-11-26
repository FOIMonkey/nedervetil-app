require 'fileutils'
require 'zip'

# Builds a temporary regulator-pack zip from sealed RawEmails with only black
# masks applied, falling back to FoiAttachment#file when the email is gone,
# manually black-redacted, or black masking cannot be verified on the original.
class RegulatorPack
  MaskingError = Class.new(StandardError)

  EXPIRES_IN = 48.hours
  VERIFIER_PURPOSE = 'regulator_pack_download'.freeze
  PACK_ID = /\A[a-f0-9]{32}\z/

  attr_reader :info_request, :user

  def self.storage_dir
    Rails.root.join('tmp', 'regulator_packs', Rails.env)
  end

  def self.verifier
    Rails.application.message_verifier(VERIFIER_PURPOSE)
  end

  def self.generate_token(pack_id:, user_id:, info_request_id:)
    verifier.generate(
      { 'pack_id' => pack_id,
        'user_id' => user_id,
        'info_request_id' => info_request_id },
      purpose: VERIFIER_PURPOSE,
      expires_in: EXPIRES_IN
    )
  end

  def self.verify_token(token)
    data = verifier.verified(token.to_s, purpose: VERIFIER_PURPOSE)
    return nil unless data.is_a?(Hash) &&
                      data['pack_id'].to_s.match?(PACK_ID) &&
                      data['user_id'].is_a?(Integer) &&
                      data['info_request_id'].is_a?(Integer)

    data.symbolize_keys
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    nil
  end

  def self.request_dir(info_request_id)
    storage_dir.join(Integer(info_request_id).to_s)
  end

  def self.path_for(pack_id, info_request_id:)
    raise ArgumentError, 'invalid pack id' unless pack_id.to_s.match?(PACK_ID)

    request_dir(info_request_id).join("#{pack_id}.zip")
  end

  def self.enqueue_for(info_request, user)
    debounce_key = "regulator_pack:#{info_request.id}:#{user.id}"
    return if Rails.cache.exist?(debounce_key)

    Rails.cache.write(debounce_key, true, expires_in: 1.minute)
    InfoRequest::RegulatorPackJob.perform_later(info_request, user)
  end

  def self.ready_path(pack_id, info_request_id:)
    path = path_for(pack_id, info_request_id: info_request_id)
    return path if File.exist?(path) && File.mtime(path) >= EXPIRES_IN.ago

    FileUtils.rm_f(path)
    nil
  end

  def self.purge_for_request!(info_request_id)
    FileUtils.rm_rf(request_dir(info_request_id))
  end

  def self.purge_expired!(older_than: EXPIRES_IN.ago)
    return 0 unless Dir.exist?(storage_dir)

    removed = 0
    Dir.glob(storage_dir.join('{*,*.zip}')).each do |entry|
      if File.directory?(entry)
        Dir.glob(File.join(entry, '*.zip')).each do |path|
          next unless File.mtime(path) < older_than

          FileUtils.rm_f(path)
          removed += 1
        end
        Dir.rmdir(entry) if Dir.empty?(entry)
      elsif File.mtime(entry) < older_than
        FileUtils.rm_f(entry)
        removed += 1
      end
    end
    removed
  end

  def initialize(info_request, user:, retry_on_masking_error: false)
    @info_request = info_request
    @user = user
    @ability = Ability.new(user)
    @retry_on_masking_error = retry_on_masking_error
  end

  def build!
    return nil unless ability.can?(:read, info_request)

    pack_id = SecureRandom.hex(16)
    target = self.class.path_for(pack_id, info_request_id: info_request.id)
    FileUtils.mkdir_p(target.dirname, mode: 0o700)
    File.chmod(0o700, target.dirname)

    partial = "#{target}.#{SecureRandom.hex(6)}.partial"
    begin
      write_zip(partial)
      File.chmod(0o600, partial)
      File.rename(partial, target)
    ensure
      FileUtils.rm_f(partial)
    end

    self.class.generate_token(pack_id: pack_id,
                              user_id: user.id,
                              info_request_id: info_request.id)
  end

  private

  attr_reader :ability

  def write_zip(file_path)
    messages = info_request.incoming_messages.order(:id).select do |message|
      ability.can?(:read, message)
    end
    messages.each(&:parse_raw_email_if_there)
    pack_bodies = build_pack_bodies(messages)
    summary = render_correspondence(pack_bodies)

    Zip::File.open(file_path, create: true) do |zipfile|
      zipfile.get_output_stream('correspondence.txt') { |f| f.write(summary) }
      messages.each_with_index do |message, index|
        message.get_attachments_for_display.each do |attachment|
          next if attachment.erased? || !ability.can?(:read, attachment)

          bytes, display_name = pack_entry_for(attachment)
          next if bytes.nil?

          filename = "#{index + 1}_#{attachment.url_part_number}_" \
                     "#{display_name}"
          zipfile.get_output_stream(filename) { |f| f.write(bytes) }
        end
      end
    end
  end

  def build_pack_bodies(messages)
    messages.each_with_object({}) do |message, result|
      main = message.get_main_body_text_part
      next unless main && !main.erased? && ability.can?(:read, main)

      result[message.id] = pack_main_body(main)
    end
  end

  def render_correspondence(pack_bodies)
    scheme = AlaveteliConfiguration.force_ssl ? 'https' : 'http'
    env = Rack::MockRequest.env_for("#{scheme}://#{AlaveteliConfiguration.domain}/")
    controller = RequestController.new
    controller.request = ActionDispatch::Request.new(env)
    controller.set_response!(ActionDispatch::Response.new)
    controller.instance_variable_set(:@current_user, user)
    controller.instance_variable_set(:@user, user)
    controller.instance_variable_set(:@current_ability, ability)
    controller.instance_variable_set(:@info_request, info_request)
    controller.instance_variable_set(:@render_to_file, true)
    controller.instance_variable_set(:@pack_bodies, pack_bodies)
    controller.render_to_string(
      template: 'request/show',
      layout: false,
      formats: [:text]
    )
  end

  def retry_on_masking_error?
    @retry_on_masking_error == true
  end

  def pack_main_body(attachment)
    if use_raw_email?(attachment)
      raw = attachment.original_attributes
      text = attachment.incoming_message.normalize_main_body(
        attachment, raw[:body], content_type: raw[:content_type]
      )
      matched = []
      masked = info_request.masks_for(:pack).apply(
        text, 'text/plain', matched: matched
      )
      if attachment.black_masked? && matched.empty?
        return stored_main_body_text(attachment)
      end

      return masked
    end

    stored_main_body_text(attachment)
  rescue Regexp::TimeoutError => e
    raise MaskingError, e.message if retry_on_masking_error?

    stored_main_body_text(attachment, skip_mask: true)
  rescue RawEmail::Erasable::ErasedError, FoiAttachment::MissingError,
         ActiveStorage::FileNotFoundError
    stored_main_body_text(attachment)
  end

  def pack_entry_for(attachment)
    if use_raw_email?(attachment)
      raw = attachment.original_attributes
      bytes = raw[:body]
      type = raw[:content_type]
      if AlaveteliTextMasker::TEXT_MASK.include?(type)
        bytes = convert_string_to_utf8(bytes.to_s, 'UTF-8').string
      end
      matched = []
      unmasked = []
      masked = info_request.masks_for(:pack).apply(
        bytes, type, matched: matched, unmasked: unmasked
      )
      unmasked -= [AlaveteliTextMasker::UNMASKED_ZIP]
      if unmasked.any? || (attachment.black_masked? && matched.empty?)
        return stored_entry_for(attachment)
      end

      if html_bytes?(attachment, type, raw[:filename])
        masked = attachment.sanitise_html(masked)
      end
      return [masked, raw_display_filename(raw[:filename], attachment)]
    end

    stored_entry_for(attachment)
  rescue AlaveteliTextMasker::PDFMaskingError, Regexp::TimeoutError => e
    raise MaskingError, e.message if retry_on_masking_error?

    stored_entry_for(attachment, skip_mask: true)
  rescue RawEmail::Erasable::ErasedError, FoiAttachment::MissingError,
         ActiveStorage::FileNotFoundError
    stored_entry_for(attachment)
  end

  def stored_entry_for(attachment, skip_mask: false)
    [stored_attachment_bytes(attachment, skip_mask: skip_mask),
     attachment.display_filename]
  end

  def stored_attachment_bytes(attachment, skip_mask: false)
    if skip_mask || attachment.masked_at.present? ||
       attachment.masking_failed?
      return download_stored_attachment(attachment)
    end

    bytes = attachment.body
    bytes.nil? ? download_stored_attachment(attachment) : bytes
  rescue AlaveteliTextMasker::PDFMaskingError, Regexp::TimeoutError => e
    raise MaskingError, e.message if retry_on_masking_error?

    download_stored_attachment(attachment)
  end

  def download_stored_attachment(attachment)
    return nil unless attachment.file.attached?

    raw = attachment.file.download
    attachment.html_attachment? ? attachment.sanitise_html(raw) : raw
  end

  def stored_main_body_text(attachment, skip_mask: false)
    if skip_mask || attachment.masked_at.present? ||
       attachment.masking_failed?
      return download_stored_main_body(attachment)
    end

    attachment.body_as_text.string
  rescue Regexp::TimeoutError => e
    raise MaskingError, e.message if retry_on_masking_error?

    download_stored_main_body(attachment)
  end

  def download_stored_main_body(attachment)
    return '' unless attachment.file.attached?

    convert_string_to_utf8(attachment.file.download, 'UTF-8').string
  end

  def html_bytes?(attachment, content_type, filename)
    type = content_type.to_s.downcase.split(';').first.to_s.strip
    return true if type == 'text/html'
    return attachment.html_attachment? if filename.blank?

    [filename, FoiAttachment.display_form(filename)].any? do |name|
      AlaveteliFileTypes.filename_to_mimetype(name) == 'text/html'
    end
  end

  def raw_display_filename(raw_name, attachment)
    return attachment.display_filename if raw_name.blank?

    masked = info_request.masks_for(:pack).apply(raw_name.to_s, 'text/plain')
    FoiAttachment.display_form(masked).presence || attachment.display_filename
  end

  def use_raw_email?(attachment)
    attachment.raw_email&.kept? && !attachment.manual_black_mask?
  end
end
