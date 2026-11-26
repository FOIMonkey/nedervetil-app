module Deadlines
  # A request's next step, worked out from its status and events: what it is,
  # who it waits for and its date.
  class NextAction
    attr_reader :request, :kind, :group, :date, :adjustment, :regime, :closure

    # attention_ids: preloaded Set of request ids with attention replies.
    def self.for(request, today: Time.zone.today, attention_ids: nil)
      new(request, today, attention_ids).tap(&:work_out)
    end

    def initialize(request, today, attention_ids = nil)
      @request = request
      @today = today
      @attention_ids = attention_ids
      @regime = Deadlines.regime(request)
    end

    def work_out
      @closure = Closure.current(request)
      return self if @closure

      follow_up = follow_up_after_reopening
      if follow_up
        set(:follow_up, :awaiting_authority, follow_up.created_at.to_date)
        return self
      end

      # Routine-only replies keep the underlying status and running deadline;
      # when attention_ids is preloaded, absence avoids a per-request query.
      status = request.calculate_status
      if status == 'waiting_classification' &&
         IncomingAttention::Effective.active? &&
         !@attention_ids&.include?(request.id)
        status = if @attention_ids
                   IncomingAttention::Effective.routine_status(request)
                 else
                   IncomingAttention::Effective.dashboard_status(request)
                 end
      end
      case status
      when 'waiting_classification'
        set(:read_reply,
            :needs_attention,
            Stage.events(request).reverse.
              find { |e| e.event_type == 'response' }&.created_at&.to_date)
      when 'waiting_response', 'waiting_response_overdue',
           'waiting_response_very_overdue'
        @adjustment = Adjustment.current(request, 'response')
        set(:response, :awaiting_authority, request.date_response_required_by)
      when 'gone_postal'
        set(:post, :awaiting_authority, request.date_response_required_by)
      when 'internal_review'
        review = Stage.review_basis(request)
        @adjustment = Adjustment.current(request, 'review')
        if review
          set(:review,
              :awaiting_authority,
              @adjustment&.due_on || Stage.computed_due_on(request, 'review'))
        end
      when 'waiting_clarification'
        set(:clarify,
            :action_required,
            Stage.events(request).reverse.
              find { |e| e.event_type == 'response' }&.created_at&.to_date)
      when 'rejected', 'partially_successful'
        after_decision
      when 'error_message'
        if (resend = sent_after_failure)
          set(:follow_up, :awaiting_authority, resend.created_at.to_date)
        else
          set(:delivery,
              :action_required,
              Stage.events(request).last&.created_at&.to_date)
        end
      end
      self
    end

    def none?
      kind.nil?
    end

    def closed?
      closure.present?
    end

    def adjusted?
      adjustment.present?
    end

    def late?
      %i[response review].include?(kind) && date.present? && @today > date
    end

    def late_days
      @late_days ||=
        late? ? Calendar.working_days_late(date, @today, regime) : 0
    end

    def days_left
      return 0 unless date && date > @today

      Calendar.working_days_between(@today, date, regime)
    end

    def basis_date
      event = case kind
              when :response, :post then Stage.response_basis(request)
              when :review then Stage.review_basis(request)
              when :ask_review then Stage.decision_response(request)
              end
      event&.created_at&.to_date
    end

    # Returns [used_pct, late_pct]; overdue bars extend through today.
    def progress
      start = basis_date
      return unless start && date && date >= start

      allowed = Calendar.working_days_between(start, date, regime)
      over = late_days
      total = allowed + over
      return [100, 0] if total.zero?

      used = if over.positive?
               allowed
             else
               Calendar.working_days_between(start, [@today, date].min, regime)
             end
      [(100.0 * used / total).round, (100.0 * over / total).round]
    end

    def scottish?
      Deadlines.scottish?(regime)
    end

    def regulator
      scottish? ? 'Scottish Information Commissioner' : 'ICO'
    end

    def review_word
      scottish? ? _('review') : _('internal review')
    end

    # Any reminder in the last week (Reminder::SPACING) counts too, so a
    # changed due date doesn't bring another.
    def reminder
      return @reminder if defined?(@reminder)

      batch = Piles::Batch.for(request)
      @reminder =
        if !late? then nil
        elsif batch then batch.reminder(self)
        else Reminder.for(request, kind, date) || Reminder.recent(request)
        end
    end

    def remindable?
      late? && reminder.nil?
    end

    # Review deadline for a late reply: required in Scotland (FOISA s.20(9),
    # EIR(S) reg 16) and allowed under EIR reg 11(2), not FOIA.
    def review_by
      return unless kind == :response && late? && regime != 'foi'

      Calendar.working_days_after(date, Deadlines.review_request_days, regime)
    end

    # FOISA s.47(4)(b): 6 months from a late review's due date to apply to SIC.
    def regulator_by
      return unless kind == :review && late? && scottish?

      date + Deadlines.sic_window
    end

    def reply_by
      return unless kind == :clarify && date

      if scottish?
        Calendar.working_days_after(date,
                                    Deadlines.clarify_scotland_days,
                                    regime)
      else
        date + Deadlines.clarify_window
      end
    end

    def label
      case kind
      when :read_reply then _('Reply received')
      when :response then late? ? _('Response overdue') : _('Response due')
      when :post then _('Reply by post expected')
      when :review
        if scottish? then late? ? _('Review overdue') : _('Review due')
        else late? ? _('Internal review overdue') : _('Internal review due')
        end
      when :clarify then _('Clarification requested')
      when :ask_review
        if scottish? then _('Ask for a review by')
        else _('Ask for an internal review by')
        end
      when :regulator
        if scottish? then _('Apply to the Commissioner by')
        else _('The ICO asks for complaints by')
        end
      when :follow_up then _('Follow-up sent')
      when :delivery then _('Delivery problem')
      end
    end

    def date_phrase(format_date)
      return unless date

      case kind
      when :response, :review
        if late?
          _('was due {{date}}', date: format_date.call(date))
        else
          format_date.call(date)
        end
      when :clarify then _('asked {{date}}', date: format_date.call(date))
      when :read_reply, :ask_review, :regulator, :follow_up
        format_date.call(date)
      when :post
        if date < @today
          _('was due {{date}}', date: format_date.call(date))
        else
          _('due {{date}}', date: format_date.call(date))
        end
      end
    end

    def detail
      parts = []
      if late_days.positive?
        parts << n_('{{count}} working day late',
                    '{{count}} working days late',
                    late_days,
                    count: late_days)
      end
      parts << _('awaiting a reply') if kind == :follow_up
      if adjusted?
        parts << _('{{reason}}, changed from {{date}}',
                   reason: adjustment.reason_label.sub(/\A./, &:downcase),
                   date: adjustment.original_due_on.strftime('%-d %b'))
      end
      parts << _('check the authority’s address') if kind == :delivery
      if kind == :clarify && reply_by
        parts << _('reply by {{date}}', date: reply_by.strftime('%-d %b'))
      end
      parts.join(' · ').presence
    end

    def adjustable_stage
      { response: 'response',
        review: 'review',
        ask_review: 'review_request' }[kind]
    end

    def law
      {
        'foi' => _('FOI'),
        'eir' => _('EIR'),
        'foisa' => _('FOISA'),
        'eisr' => _('EIR (Scotland)')
      }.fetch(regime, regime.upcase)
    end

    def timeline
      steps = []
      sent = Stage.response_basis(request)
      steps << [_('Request sent'), sent.created_at.to_date] if sent
      response_change = Adjustment.current(request, 'response')
      if response_change&.reason == 'public_interest'
        steps << [_('Refusal notice due'), response_change.original_due_on]
      end
      steps << [
        _('Response due'),
        request.date_response_required_by,
        response_change &&
        _('was {{date}}',
          date: response_change.original_due_on.strftime('%-d %b'))
      ]
      review = Stage.review_basis(request)
      decision = Stage.decision_response(request, review)
      if decision &&
         (review ||
          %w[rejected partially_successful successful].
            include?(request.described_state))
        steps << [_('Decision received'), decision.created_at.to_date]
      end
      add_review_steps(steps, review) if review
      add_closing_steps(steps)
      steps
    end

    def superseded_adjustment
      stage = adjustable_stage or return
      latest = Adjustment.active_for(request, stage: stage).order(:id).last
      latest if latest&.superseded?
    end

    private

    def no_response_after?(events, event)
      events.none? do |other|
        other.event_type == 'response' && other.id > event.id
      end
    end

    def set(kind, group, date)
      @kind = kind
      @group = group
      @date = date
    end

    # Only a resend of the failed message itself clears the delivery error.
    def sent_after_failure
      events = Stage.events(request)
      failure = events.reverse.
        find { |event| event.event_type == 'send_error' } or return
      later = events.select { |event| event.id > failure.id }
      sent = later.reverse.find do |event|
        event.outgoing_message_id == failure.outgoing_message_id &&
          %w[sent resent followup_sent followup_resent].
            include?(event.event_type)
      end
      sent if sent && no_response_after?(later, sent)
    end

    # Core keeps a final status after a post-closure follow-up, so return that
    # follow-up (no statutory deadline) when no reply has followed it.
    def follow_up_after_reopening
      last_closure = Closure.latest(request)
      return unless last_closure
      unless Closure::FINAL_STATES.include?(request.described_state) &&
             !request.awaiting_description?
        return
      end

      later = Stage.events(request).
        select { |event| event.id > last_closure.basis_event_id }
      follow_up = later.reverse.find do |event|
        %w[followup_sent followup_resent].include?(event.event_type)
      end
      follow_up if follow_up && no_response_after?(later, follow_up)
    end

    def after_decision
      review = Stage.review_basis(request)
      if review
        answer = Stage.review_response(request, review) or return
        closes = answer.created_at.to_date +
                 (scottish? ? Deadlines.sic_window : Deadlines.ico_window)
        set(:regulator, :action_required, closes) if closes >= @today
      else
        Stage.decision_response(request) or return
        @adjustment = Adjustment.current(request, 'review_request')
        closes = @adjustment&.due_on ||
                 Stage.computed_due_on(request, 'review_request')
        set(:ask_review, :action_required, closes) if closes >= @today
      end
    end

    def add_review_steps(steps, review)
      steps << [
        scottish? ? _('Review requested') : _('Internal review requested'),
        review.created_at.to_date
      ]
      review_change = Adjustment.current(request, 'review')
      steps << [
        scottish? ? _('Review due') : _('Internal review due'),
        review_change&.due_on || Stage.computed_due_on(request, 'review'),
        review_change &&
        _('was {{date}}',
          date: review_change.original_due_on.strftime('%-d %b'))
      ]
      answer = Stage.review_response(request, review)
      if answer
        steps << [_('Review response received'), answer.created_at.to_date]
      end
      steps << [_('Apply to the Commissioner by'), regulator_by] if regulator_by
    end

    def add_closing_steps(steps)
      if kind == :ask_review
        steps << [
          label,
          date,
          adjustment &&
          _('was {{date}}',
            date: adjustment.original_due_on.strftime('%-d %b'))
        ]
      elsif review_by
        steps << [
          if scottish? then _('Ask for a review by')
          else _('Ask for an internal review by')
          end,
          review_by
        ]
      elsif kind == :regulator
        steps << [label, date]
      end
    end
  end
end
