require 'json'

module IncomingAttention
  # Builds the masked triage payload for the AI service from core's parsed
  # reply text and redacted attachment filenames.
  class Input
    # Model state limit and Worker framing bytes; reply text is trimmed to fit
    # so no unread text is sent.
    STATE_BYTES = 8_192
    FRAME_BYTES = 201
    Snapshot = Struct.new(:request, :restrictions, :info_request_id,
                          :response_event_id, keyword_init: true)
    # Raised when a reply can't be read; code says why.
    class Unavailable < StandardError
      attr_reader :code

      def initialize(code)
        @code = code
        super(code)
      end
    end

    def self.available?(message)
      return false unless message && message.info_request

      request = message.info_request
      if request.holding_pen_request?(read_only: true) || !message.raw_email ||
         message.raw_email.erased_at
        return false
      end
      # A requester who closed their account chose to leave, so their replies
      # aren't read. A banned requester's replies are read like anyone else's.
      return false if request.user&.closed?

      readable_by_requester?(request, message)
    end

    def self.waiting_for_analysis_since(message)
      return nil unless readable_envelope?(message)

      ability = Ability.new(message.info_request.user)
      return nil unless ability.can?(:read, message.info_request) &&
                        ability.can?(:read, message)

      parts = message.foi_attachments.includes(file_attachment: :blob).to_a
      waiting = parts.select { |part| FoiAttachment::SpreadsheetHold.waiting?(part) }
      return nil if waiting.empty?
      unless (parts - waiting).all? { |part| ability.can?(:read, part) }
        return nil
      end

      waiting.filter_map { |part| part.file_blob&.created_at }.min
    end

    def self.waiting_for_analysis?(message)
      !waiting_for_analysis_since(message).nil?
    end

    def self.readable_envelope?(message)
      return false unless message && message.info_request

      request = message.info_request
      !request.holding_pen_request?(read_only: true) &&
        message.raw_email.present? &&
        message.raw_email.erased_at.nil? &&
        !request.user&.closed?
    end
    private_class_method :readable_envelope?

    def self.unavailable_code(message, fallback)
      waiting_for_analysis?(message) ? 'analysis_pending' : fallback
    end

    def self.readable_by_requester?(request, message)
      ability = Ability.new(request.user)
      ability.can?(:read, request) && ability.can?(:read, message) &&
        message.foi_attachments.all? { |part| ability.can?(:read, part) }
    end
    private_class_method :readable_by_requester?

    # Returns [body, shortened], trimmed at a UTF-8 boundary to fit STATE_BYTES.
    def self.prepare(body, metadata)
      if !body.is_a?(String) || body.strip.empty?
        raise Unavailable, 'body_empty'
      end
      raise Unavailable, 'invalid_unicode' unless body.valid_encoding?

      body = body.encode(Encoding::UTF_8)
      budget = STATE_BYTES - FRAME_BYTES - JSON.generate(metadata).bytesize
      raise Unavailable, 'input_limit' if budget < 1

      shortened = body.bytesize > budget
      if shortened
        body = body.byteslice(0, budget)
        body = body.byteslice(0, body.bytesize - 1) until body.valid_encoding?
      end
      raise Unavailable, 'body_empty' if body.strip.empty?

      [body, shortened]
    end

    def self.build(message)
      unless available?(message)
        raise Unavailable, unavailable_code(message, 'source_unavailable')
      end

      event = message.response_event
      unless event && event.info_request_id == message.info_request_id
        raise Unavailable, 'response_event_missing'
      end

      # Core's folding strips quoted history; only shortening beyond that
      # rules out SKIP.
      message.parse_raw_email
      parts = message.foi_attachments.reload.to_a
      ability = Ability.new(message.info_request.user)
      unless parts.all? { |part| ability.can?(:read, part) }
        raise Unavailable, unavailable_code(message, 'attachment_unavailable')
      end
      raise Unavailable, 'masking_failed' if parts.any?(&:masking_failed_at)

      main = message.get_main_body_text_part(parts)
      raise Unavailable, 'body_unavailable' unless main && !main.erased_at

      message.main_body_text!

      body = message.apply_all_masks(message.get_body_for_quoting,
                                     'text/html',
                                     redacted_attribute: :body)
      if message.cached_main_body_text_unfolded.blank? ||
         body.include?('[ Email has no body, please see attachments ]')
        raise Unavailable, 'body_unavailable'
      end

      files = parts.reject { |part| part.id == main.id }
      available = files.none? do |part|
        part.erased_at || part.redacted_filename.blank?
      end
      names = if available
                files.map do |part|
                  message.info_request.apply_censor_rules(
                    part.redacted_filename, 'text/plain',
                    redactable: part,
                    redacted_attribute: :filename
                  )
                end
              else
                []
              end
      # Image names stay here: only how many there are is sent.
      images, documents = names.partition do |name|
        FoiAttachment::Content.image_filename?(name)
      end
      metadata = { 'attachment_filenames_available' => available,
                   'non_image_attachment_filenames' => documents,
                   'image_attachments_ignored' => images.size }
      body, shortened = prepare(body, metadata)
      restrictions = available ? [] : ['unsupported_metadata']
      Snapshot.new(
        request: Config.contract.merge(
          'message_id' => message.id.to_s,
          'info_request_id' => message.info_request_id.to_s,
          'body' => body,
          'body_shortened' => shortened,
          'attachments' => { 'available' => available,
                             'filenames' => documents,
                             'images_ignored' => images.size }
        ),
        restrictions: restrictions,
        info_request_id: message.info_request_id,
        response_event_id: event.id
      )
    rescue Unavailable
      raise
    rescue MailHandler::ReadRefused
      # Unreadable mail retries later via masking_pending.
      raise Unavailable, 'masking_pending'
    rescue StandardError => e
      Rails.logger.warn('incoming_attention_input_preparation_failed ' \
                        "message_id=#{message.id} #{e.class}")
      raise Unavailable, 'input_preparation_failed'
    end
  end
end
