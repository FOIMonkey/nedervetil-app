module Deadlines
  # A reply as the request page first shows it: only what the system knows
  # without reading it.
  class Reply
    ANSWERS = { 'all' => 'successful',
                'some' => 'partially_successful',
                'none' => 'rejected' }.freeze
    LABELS = { 'all' => N_('All of it'),
               'some' => N_('Some of it'),
               'none' => N_('None of it') }.freeze
    GOT = { 'all' => N_('You got all of it'),
            'some' => N_('You got some of it'),
            'none' => N_('You got none of it') }.freeze
    EXCERPT = 240
    SIGN_OFF = /^[ \t]*(yours\s+(sincerely|faithfully|truly)|
                        (kind|best|many|warm)\s+(regards|wishes|thanks)|
                        regards|thanks|thank\s+you),?[ \t]*$/ix
    SENT = %w[sent resent followup_sent followup_resent].freeze

    attr_reader :request, :event, :message

    def self.latest(request, ability)
      event = Stage.events(request).reverse.find do |candidate|
        candidate.event_type == 'response' && candidate.incoming_message &&
          ability.can?(:read, candidate.incoming_message)
      end
      event && new(request, event, ability)
    end

    def initialize(request, event, ability)
      @request = request
      @event = event
      @message = event.incoming_message
      @ability = ability
      @regime = Deadlines.regime(request)
    end

    def date
      (message.sent_at || event.created_at).to_date
    end

    def due
      review = Stage.review_basis(request)
      if review && review.id < event.id
        Adjustment.current(request, 'review')&.due_on ||
          Stage.computed_due_on(request, 'review')
      else
        request.date_response_required_by
      end
    end

    def late?
      due.present? && date > due
    end

    def last?
      Stage.events(request).none? do |other|
        other.id > event.id && SENT.include?(other.event_type)
      end
    end

    def ask?
      request.awaiting_description? && last?
    end

    def answer
      ANSWERS.key(History.status(request, event))
    end

    def being_read?
      last? && defined?(IncomingAttention::Effective) &&
        IncomingAttention::Effective.notification_pending?(message)
    end

    def first_line
      excerpt.to_s.split(/(?<=[.!?])\s/).first.to_s.
        truncate(90, separator: ' ').presence
    end

    def excerpt
      part = message.get_main_body_text_part
      return if part.nil? || !@ability.can?(:read, part)

      text = message.get_main_body_text_folded.to_s.
        split('FOLDED_QUOTED_SECTION').first.to_s
      text = without_signature(text).
        sub(/\A\s*(dear|hello|hi|good (morning|afternoon))\b[^\n]*\n/i, '').
        squish
      return if text.empty?
      return text if text.length <= EXCERPT

      cut = text.first(EXCERPT)
      sentence = cut.rindex(/[.!?](\s|\z)/)
      if sentence && sentence > EXCERPT / 2
        cut[0..sentence]
      else
        "#{cut.sub(/\s+\S*\z/, '')}…"
      end
    end

    def files
      message.get_attachments_for_display.select do |file|
        @ability.can?(:read, file)
      end
    end

    # Uses the decision's review deadline (including adjustments), falling back
    # to this reply's own review window while unclassified.
    def review_by
      if ask? || Stage.decision_response(request).nil?
        Calendar.working_days_after(
          Stage.review_window_start(request, event, @regime),
          Deadlines.review_request_days,
          @regime
        )
      else
        Adjustment.current(request, 'review_request')&.due_on ||
          Stage.computed_due_on(request, 'review_request')
      end
    end

    def review_open?(today = Time.zone.today)
      Stage.review_basis(request).nil? && answer != 'all' && review_by >= today
    end

    private

    def without_signature(text)
      text = text[0...text.index(SIGN_OFF)] if text.match?(SIGN_OFF)
      paragraphs = text.strip.split(/\n\s*\n/)
      if paragraphs.size > 1 && paragraphs.last.length < 80 &&
         !paragraphs.last.match?(/[.!?:]\s*\z/)
        paragraphs.pop
      end
      paragraphs.join("\n\n")
    end
  end
end
