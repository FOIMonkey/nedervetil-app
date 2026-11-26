module Disclosures
  # Classifies reply parts to label "Make document" buttons using regexes over
  # extracted text (no AI). Unreadable files still save a row so they don't
  # stall the reply or re-queue the job.
  class Suggester
    RULE_VERSION = 6
    IMAGES = (IncomingAttention::Input::IMAGE_EXTENSIONS +
              %w[emz wmz emf wmf heic]).map { |ext| ".#{ext}" }.freeze
    # Images over this size may be photographed letters.
    LARGE_IMAGE = 300.kilobytes
    LETTER = IncomingAttention::Outcome::LetterPick::LETTER
    RESPONSE_NAME = IncomingAttention::Outcome::LetterPick::RESPONSE_NAME
    ABOUT_REQUEST = IncomingAttention::Outcome::LetterPick::ABOUT_REQUEST
    REGIME = IncomingAttention::Outcome::LetterPick::REGIME
    WEAK_RESPONSE_NAME = /correspond|newsletter|responsib/i
    # rubocop:disable Layout/LineLength
    ROUTINE = /\backnowledge?ment\b|\backnowledge receipt|now being considered|has been (?:received|logged)|fees? notice|(?:requires?|need) (?:further|some) (?:information|clarification)|please (?:can you )?(?:clarify|advise)|extend(?:ed)? the (?:time|deadline)|public interest test.{0,40}(?:extend|additional time)/i
    DECISION = Regexp.union(
      /\b(?:do(?:es)?\s+not|don.t|doesn.t|did\s+not)\s+(?:hold|have|retain|keep|record)\b|\bnot\s+held\b|\bno\s+(?:recorded\s+)?information\s+(?:is\s+)?held\b/i,
      /\bsection\s*(?:1[24]|2[1-9]|3\d|4[0-4])[a-z]?\b|\bexempt(?:ion|ed)?\b|\bwithh[oe]ld\b|\bneither\s+confirm\s+nor\s+deny\b|\bpublic\s+interest\b|\brefusal\s+notice\b/i,
      /\b(?:unable|not\s+able)\s+to\s+(?:provide|comply|supply|disclose|release)\b|\bcannot\s+(?:provide|comply|supply|disclose|release)\b|\b(?:refuse|refused|refusing)\b/i,
      /\bappropriate\s+limit\b|\bcost\s+(?:limit|threshold)\b|\b(?:would|will)\s+exceed\b|\bvexatious\b|\bmanifestly\s+unreasonable\b/i,
      /\b(?:information|data)\s+(?:you\s+(?:have\s+)?requested\s+|requested\s+)?(?:is|are)\s+held\b|\binternal\s+review\s+(?:has\s+been|was)\s+(?:completed|carried\s+out)\b|\b(?:uphold|upheld|overturn(?:ed)?)\b/i,
      /\breasonably\s+accessible\b|\bpublished\s+(?:on|at)\b|\b(?:transferred|forwarded)\s+(?:your\s+request\s+)?to\b/i,
      /\bplease\s+find\s+(?:the\s+)?(?:information|response|attached)\b|\b(?:is|are)\s+(?:attached|enclosed)\b/i
    )
    # rubocop:enable Layout/LineLength
    LABELS = {
      'decision_letter' => N_('Decision letter'),
      'released_records' => N_('Released records'),
      'set_aside' => N_('Set aside'),
      'look' => N_('Have a look')
    }.freeze

    Result = Struct.new(:suggestion, :rule, :reason, :confident,
                        keyword_init: true)
    # Shown beside "The email", so they don't say it again (Suggestion#reason).
    EMAIL_REASONS = {
      'email_with_letter' => N_('Usually not needed'),
      'email_routine' => N_('Usually not needed'),
      'email' => N_('Usually not needed')
    }.freeze

    attr_reader :message, :request

    def initialize(message)
      @message = message
      @request = message.info_request
    end

    def self.fingerprint(part)
      Digest::SHA1.hexdigest(
        [RULE_VERSION,
         IncomingAttention::Outcome::Input.fingerprint(part)].to_json
      )
    end

    # The parts that get a row. The Panel waits only for these.
    def self.eligible?(part)
      !part.erased? && !part.masking_failed?
    end

    def run
      # Raises if mail is unreadable so the job retries.
      message.parse_raw_email
      parts = message.get_attachments_for_display.
        filter_map { |part| FoiAttachment.find_by(id: part.id) }
      results = {}
      letters = []
      @opened = 0
      @started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      parts.each do |part|
        next unless self.class.eligible?(part)

        result, text = unreadable(part) { classify(part) }
        results[part] = result
        letters << [part, text] if result.suggestion == 'pending_letter'
      end
      pick_letter(letters, results)
      main = message.get_main_body_text_part
      if main && !main.erased?
        results[main] =
          unreadable(main, email: true) { email_result(results.values) }
      end
      save(results)
    end

    private

    def unreadable(part, email: false)
      yield
    rescue MailHandler::ReadRefused
      # Transient mail read refusal; retry rather than marking unreadable.
      raise
    rescue StandardError => e
      Rails.logger.warn("Disclosures::Suggester couldn’t read part " \
                        "#{part.id}: #{e.class}: #{e.message}")
      if email
        result('none',
               'email_unreadable',
               N_('The reply’s own text couldn’t be read or masked here.'))
      else
        result('look',
               'unreadable',
               N_('This file couldn’t be read here: have a look at it.'))
      end
    end

    def classify(part)
      name = part.display_filename
      format = Formats.for(part.content_type, name)
      if Formats::SUPPORTED.include?(format)
        unless within_limits?(part)
          return [result(
            'look', 'over_limit',
            N_('This file couldn’t be read here: have a look at it.')
          )]
        end

        format = Formats.for(part.content_type, name, part.body)
      end
      unless Formats::SUPPORTED.include?(format)
        large = IMAGES.include?(Formats.extension(name)) &&
                part.file_blob&.byte_size.to_i > LARGE_IMAGE
        return [result(
          'none', large ? 'large_image' : 'format',
          N_('This kind of file can’t become a document.')
        )]
      end
      if %w[spreadsheet csv].include?(format)
        return [result(
          'released_records', 'spreadsheet',
          N_('A spreadsheet or CSV file.')
        )]
      end

      text = readable_text(part)
      if text.strip.length < 80
        return [result(
          'look', 'no_text',
          N_('No text to read: a scan, or a file this site can’t read.')
        )]
      end

      aside = set_aside_result(name, text)
      return [aside] if aside

      [Result.new(suggestion: 'pending_letter'), text]
    end

    def set_aside_result(name, text)
      head = text[0, 3000].split.join(' ')
      if IncomingAttention::Outcome::LetterPick.leaflet?(name, head)
        return result(
          'set_aside', 'leaflet',
          N_('Looks like a leaflet or a notice of your rights.')
        )
      end
      if name.match?(/acknowledg/i)
        return result(
          'set_aside', 'routine',
          N_('Its name says it is an acknowledgement.')
        )
      end
      if name.match?(/form.?details/i) ||
         (request_share(text) >= 0.6 && !name.match?(RESPONSE_NAME))
        return result(
          'set_aside', 'request_copy',
          N_('Looks like a copy of the request.')
        )
      end

      nil
    end

    # Keyed by attachment; highest score >= LetterPick::FLOOR wins.
    def pick_letter(letters, results)
      scored = letters.filter_map do |part, text|
        score = IncomingAttention::Outcome::LetterPick.score(
          part.display_filename, text
        )
        [score, part, text] if score
      end
      best = scored.max_by { |score, part, _| [score, -part.id] }
      letters.each do |part, text|
        head = text[0, 3000].split.join(' ')
        results[part] =
          if best && best[1] == part &&
             best[0] >= IncomingAttention::Outcome::LetterPick::FLOOR
            letter_result(part, head)
          elsif head.scan(LETTER).size >= 2
            result('released_records',
                   'letter_like',
                   N_('A letter, but not the reply to the request: check.'))
          else
            result('released_records',
                   'records',
                   N_('Doesn’t read as a letter.'))
          end
      end
    end

    def letter_result(part, head)
      if head.match?(ROUTINE) && !head.match?(DECISION)
        result('set_aside',
               'routine',
               N_('Reads as a routine letter (acknowledgement, ' \
                  'extension or clarification).'))
      else
        confident = head[0, 1500].match?(ABOUT_REQUEST) ||
                    head[0, 1500].match?(REGIME)
        confident &&= !part.display_filename.match?(WEAK_RESPONSE_NAME)
        note = if confident
                 N_('Reads as the reply to the request.')
               else
                 N_('Reads as a letter; check it is the decision.')
               end
        result('decision_letter', 'letter_pick', note,
               confident: confident)
      end
    end

    def email_result(file_results)
      text = message.get_main_body_text_part&.body_as_text&.string.to_s
      head = text[0, 3000].split.join(' ')
      if file_results.any? { |result| result.suggestion == 'decision_letter' }
        result('set_aside',
               'email_with_letter',
               EMAIL_REASONS['email_with_letter'])
      elsif file_results.
              any? { |result| %w[no_text large_image].include?(result.rule) }
        result('look',
               'email_with_scan',
               N_('The decision is in the email or in the scan: ' \
                  'have a look at both.'))
      elsif text.strip.length >= 80 && head.match?(DECISION)
        result('decision_letter',
               'email_decision',
               N_('The decision is in the email itself.'),
               confident: head.match?(ABOUT_REQUEST))
      elsif head.match?(ROUTINE)
        result('set_aside', 'email_routine', EMAIL_REASONS['email_routine'])
      else
        result('set_aside', 'email', EMAIL_REASONS['email'])
      end
    end

    # Enforces Outcome::Input extraction caps across all opened files.
    def within_limits?(part)
      input = IncomingAttention::Outcome::Input
      size = part.file_blob&.byte_size
      return false if @opened >= input::MAX_DOCUMENTS ||
                      (size && size > input::MAX_DOCUMENT_BYTES) ||
                      Process.clock_gettime(
                        Process::CLOCK_MONOTONIC
                      ) - @started > input::EXTRACTION_SECONDS

      @opened += 1
      true
    end

    def readable_text(part)
      IncomingAttention::Outcome::Input.document_text(part).to_s
    end

    # Overlap of 3-word shingles with the requester's masked outgoing messages.
    def request_share(text)
      mine = shingles(text)
      return 0.0 if mine.empty?

      asked = request.outgoing_messages.flat_map do |outgoing|
        shingles(
          IncomingAttention::Outcome::Input.asked(request, outgoing)
        ).to_a
      end.to_set
      (mine & asked).size.to_f / mine.size
    end

    def shingles(text)
      words = text.to_s.downcase.gsub(%r{https?://\S+|www\.\S+}, ' u ').
        gsub(/[\w.+-]+@[\w-]+(?:\.[\w-]+)+/, ' e ').
        gsub(/\d+/, '#').gsub(/[^a-z#]+/, ' ').split
      (0..(words.size - 3)).to_set { |index| words[index, 3].join(' ') }
    end

    def result(suggestion, rule, reason, confident: false)
      Result.new(suggestion: suggestion,
                 rule: rule,
                 reason: reason,
                 confident: confident)
    end

    # Reloaded: reading a file can have masked it since it was loaded.
    def save(results)
      results.each do |part, outcome|
        part.reload
        row = Suggestion.find_or_initialize_by(foi_attachment_id: part.id)
        row.update!(incoming_message_id: message.id,
                    fingerprint: self.class.fingerprint(part),
                    rule_version: RULE_VERSION,
                    suggestion: outcome.suggestion,
                    rule: outcome.rule,
                    reason: outcome.reason,
                    confident: outcome.confident,
                    display_name: part.display_filename,
                    content_type: part.content_type,
                    byte_size: part.file_blob&.byte_size)
      end
    end
  end
end
