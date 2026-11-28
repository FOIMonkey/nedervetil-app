module IncomingAttention
  module Outcome
    # Builds masked, censor-filtered outcome payloads; includes unfolded reply
    # text when core folded quoted sections (answers are often inline).
    module Input
      Built = Struct.new(:request, :signals, :sources, keyword_init: true)
      Unavailable = IncomingAttention::Input::Unavailable
      REQUEST_CHARS = 1_500
      LETTER_CHARS = 6_000
      OTHER_CHARS = 900
      UNFOLDED_CHARS = 8_000
      # The model state's size, and the byte counts of the Worker's framing (not
      # its wording), so no more text is sent than fits the state.
      SHARE_BYTES = 32_000
      FRAME = { request: 42,
                request_note: 25,
                reply: 36,
                unfolded: 87,
                open: 17,
                letter: 23,
                other: 18 }.freeze
      FOLDED = 'FOLDED_QUOTED_SECTION'.freeze
      READABLE = (FoiAttachment::LetterPick::DOCS +
                  %w[.xlsx .xls .ods .csv]).freeze

      module_function

      def build(message)
        unless IncomingAttention::Input.available?(message)
          code = IncomingAttention::Input.
                 unavailable_code(message, 'source_unavailable')
          raise Unavailable, code
        end

        message = IncomingMessage.find(message.id)
        request = message.info_request
        ability = Ability.new(request.user)
        unread_is_pending { message.parse_raw_email }
        all_parts = message.foi_attachments.reload.to_a
        if all_parts.any?(&:masking_failed_at)
          raise Unavailable, 'masking_failed'
        end

        main = message.get_main_body_text_part(all_parts)
        raise Unavailable, 'body_unavailable' unless main && !main.erased_at
        raise Unavailable, 'masking_pending' if pending_mask?(main)

        outgoing = request.outgoing_messages.order(:id).first
        unless outgoing && ability.can?(:read, outgoing)
          raise Unavailable, 'request_unavailable'
        end

        sources = { 'user_id' => request.user_id,
                    'outgoing' => [outgoing.id, outgoing.updated_at.to_f,
                                   outgoing.prominence],
                    'parts' => {},
                    'censor' => censor_print(request) }
        main = prepared_part(main)
        prints = sources['parts']
        prints[main.id.to_s] = FoiAttachment::Content.fingerprint(main)
        # Drops body caches that masking or a replacement made stale.
        message.reload
        folded = unread_is_pending do
          message.main_body_text!(folded: true).to_s
        end
        shown = message.apply_all_masks(
          folded.gsub(FOLDED, "\n[quoted section folded]\n").strip,
          'text/html',
          redacted_attribute: :body
        )
        raise Unavailable, 'body_unavailable' if shown.blank?

        unfolded = if folded.include?(FOLDED)
                     message.apply_all_masks(
                       message.main_body_text!.to_s,
                       'text/html',
                       redacted_attribute: :body
                     )[0, UNFOLDED_CHARS]
                   end
        # Fingerprint each source before reading; recheck! catches any
        # replacement, hide, or erasure before the payload is sent.
        ocr = []
        documents, omitted =
          read_documents(message, request, ability, prints, ocr)
        letter = FoiAttachment::LetterPick.pick(documents)
        excerpts = documents.filter_map do |name, body|
          if name == letter
            { 'name' => name,
              'text' => body.split.join(' ')[0, LETTER_CHARS],
              'letter' => true }
          elsif !FoiAttachment::LetterPick.leaflet?(name, body)
            { 'name' => name,
              'text' => body.strip[0, OTHER_CHARS],
              'letter' => false }
          end
        end
        asked = FoiAttachment::Content.asked(request, outgoing)
        shared = share(asked[0, REQUEST_CHARS],
                       asked.length > REQUEST_CHARS,
                       shown,
                       unfolded,
                       excerpts)
        # Extract citations from authority text only so a request asking about
        # a section is not misread as a refusal.
        authority = [
          shared['reply'],
          shared['reply_unfolded'],
          *shared['documents'].flat_map { |doc| [doc['name'], doc['text']] }
        ]
        cited = authority.compact.
          flat_map { |piece| Signals.cited(piece, request.legislation) }.uniq
        signals = { 'cited' => cited,
                    'folded' => folded.include?(FOLDED),
                    'letter' => letter,
                    'documents' => documents.size,
                    'omitted' => omitted,
                    'ocr' => ocr.size }
        Built.new(signals: signals,
                  sources: sources,
                  request: {
                    'contract_version' => 'request-outcome/v2',
                    'message_id' => message.id.to_s,
                    'info_request_id' => request.id.to_s,
                    'request_text' => shared['request_text'],
                    'request_shortened' => asked.length > REQUEST_CHARS,
                    'reply' => shared['reply'],
                    'reply_unfolded' => shared['reply_unfolded'],
                    'documents' => shared['documents'],
                    'text_shortened' => shared['text_shortened'],
                    'omitted_documents' => omitted.size,
                    'cited_sections' => cited,
                    'strict_documents' => Outcome.strict_documents?
                  })
      end

      # Packs pieces and framing bytes up to SHARE_BYTES, splitting only on a
      # UTF-8 character boundary.
      def share(request_text, request_shortened, reply, unfolded, documents)
        left = SHARE_BYTES
        full = false
        frame = ->(bytes) do
          return false if full

          left -= bytes
          full = true if left.negative?
          left = 0 if full
          true
        end
        take = ->(text) do
          return '' if full
          return text.tap { left -= text.bytesize } if text.bytesize <= left

          full = true
          size = left
          until size >= text.bytesize ||
                text.byteslice(0, size).valid_encoding?
            size += 1
          end
          left = 0
          text.byteslice(0, size)
        end
        frame.call(FRAME[:request])
        shared = { 'request_text' => take.call(request_text) }
        frame.call(FRAME[:request_note]) if request_shortened
        frame.call(FRAME[:reply])
        shared['reply'] = take.call(reply)
        shared['reply_unfolded'] =
          unfolded && frame.call(FRAME[:unfolded]) ? take.call(unfolded) : nil
        shared['documents'] = []
        documents.each do |doc|
          break unless frame.call(FRAME[:open])

          name = take.call(doc['name'])
          frame.call(doc['letter'] ? FRAME[:letter] : FRAME[:other])
          shared['documents'] << doc.merge('name' => name,
                                           'text' => take.call(doc['text']))
        end
        shared.merge('text_shortened' => full)
      end

      # [[name, text], ...] for the documents read in full, and the omitted ones
      # as {"name" => reason}. Images and erased parts are neither.
      def read_documents(message, request, ability, prints, ocr = [])
        content = FoiAttachment::Content
        documents = []
        omitted = {}
        attempts = 0
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        message.get_attachments_for_display.each do |part|
          name = name_of(request, part)
          next if part.erased_at || name.blank? || content.image_filename?(name)

          unless ability.can?(:read, part)
            if FoiAttachment::SpreadsheetHold.waiting?(part)
              raise Unavailable, 'analysis_pending'
            end

            raise Unavailable, 'source_unavailable'
          end
          raise Unavailable, 'masking_pending' if pending_mask?(part)

          size = part.file.attached? ? part.file.blob.byte_size : nil
          reason =
            if !READABLE.include?(File.extname(name).downcase)
              'unreadable_type'
            elsif documents.size >= content::MAX_DOCUMENTS
              'too_many'
            elsif size.nil?
              'size_unknown'
            elsif size > content::MAX_DOCUMENT_BYTES
              'too_large'
            elsif Process.clock_gettime(Process::CLOCK_MONOTONIC) - started >
                  content::EXTRACTION_SECONDS
              'out_of_time'
            end
          next omitted[name] = reason if reason

          part = prepared_part(part)
          prints[part.id.to_s] ||= content.fingerprint(part)
          name = name_of(request, part)
          if part.file.blob.byte_size > content::MAX_DOCUMENT_BYTES
            next omitted[name] = 'too_large'
          end

          body = content.document_text(part)
          # Count OCR attempts (not successes) so failing scans cannot exhaust
          # the extraction budget.
          if (body.nil? || body.strip.length < 80) && pdf?(name, part) &&
             attempts < FoiAttachment::Ocr::MAX_DOCUMENTS &&
             Process.clock_gettime(Process::CLOCK_MONOTONIC) - started <=
             content::EXTRACTION_SECONDS && Outcome.ocr?
            attempts += 1
            scanned = scanned_text(part)
            if scanned && scanned.strip.length >= 80
              body = scanned
              ocr << name
            end
          end
          next omitted[name] = 'no_text' unless body && body.strip.length >= 80

          documents << [name, body]
        end
        [documents, omitted]
      end

      # Verifies immediately before sending that owner, visibility, censor
      # rules, and every read source are unchanged since extraction.
      def recheck!(message, built)
        message.reload
        request = message.info_request.reload
        OptOut.guard!(request)
        ability = Ability.new(request.user)
        outgoing = request.outgoing_messages.
          find_by(id: built.sources['outgoing'].first)
        same = IncomingAttention::Input.available?(message) &&
               request.user_id == built.sources['user_id'] &&
               outgoing && ability.can?(:read, outgoing) &&
               [outgoing.id, outgoing.updated_at.to_f, outgoing.prominence] ==
               built.sources['outgoing'] &&
               censor_print(request) == built.sources['censor']
        parts = FoiAttachment.where(id: built.sources['parts'].keys).
          index_by { |part| part.id.to_s }
        same &&= built.sources['parts'].all? do |id, print|
          part_unchanged?(parts[id], message, ability, print)
        end
        raise Unavailable, 'source_changed' unless same
      end

      def part_unchanged?(part, message, ability, print)
        part && part.incoming_message_id == message.id &&
          ability.can?(:read, part) && !pending_mask?(part) &&
          FoiAttachment::Content.fingerprint(part) == print
      end

      def unread_is_pending
        yield
      rescue MailHandler::ReadRefused
        raise Unavailable, 'masking_pending'
      end

      # Trigger first-read masking before snapshotting and reload so a stale
      # @cached_body cannot outlast a replacement.
      def prepared_part(part)
        part = FoiAttachment.find(part.id)
        raise Unavailable, 'source_changed' if part.erased?
        raise Unavailable, 'masking_pending' if pending_mask?(part)

        unread_is_pending { part.body unless part.masked? }
        part = FoiAttachment.find(part.id)
        raise Unavailable, 'source_changed' if part.erased?
        raise Unavailable, 'masking_failed' if part.masking_failed?
        raise Unavailable, 'masking_pending' unless part.masked?

        part
      end

      def censor_print(request)
        request.applicable_censor_rules.
          map { |rule| [rule.id, rule.updated_at&.to_f] }.sort_by(&:first)
      end

      def pending_mask?(_part)
        false
      end

      def name_of(request, part)
        request.apply_censor_rules(part.redacted_filename.to_s, 'text/plain',
                                   redactable: part,
                                   redacted_attribute: :filename)
      end

      def pdf?(name, part)
        part.content_type == 'application/pdf' ||
          File.extname(name).casecmp?('.pdf')
      end

      # OCRs only the served #body (never #unmasked_body) and re-applies masks
      # since scanned image text cannot carry prior text redactions.
      def scanned_text(part)
        text = FoiAttachment::Ocr.pdf_text(part.body)
        text && part.apply_all_masks(text,
                                     'text/html',
                                     redacted_attribute: :body_to_text)
      rescue StandardError => e
        Rails.logger.warn('request_outcome_scanned_text_failed ' \
                          "attachment_id=#{part&.id} #{e.class}")
        nil
      end
    end
  end
end
