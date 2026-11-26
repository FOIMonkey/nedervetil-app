module Deadlines
  # Builds the chronological "What happened" timeline for a request from stored
  # events, statuses, adjustments, documents, and closures.
  class History
    Entry = Struct.new(:at, :kind, :title, :meta, :timing, :line, :event,
                       :documents, keyword_init: true) do
      def date
        at.to_date
      end
    end

    STATUSES = (Stage::OUTCOMES + %w[waiting_clarification]).freeze
    # The hedged "likely decision" label is left out.
    LABELS = [
      *IncomingAttention::Labels::ROUTINE.values,
      *IncomingAttention::Labels::ATTENTION.
        values_at('DELIVERY_PROBLEM', 'ACTION_REQUESTED', 'SUBSTANTIVE')
    ].freeze

    def self.reply_suffix(request, event)
      message = event.incoming_message or return
      prediction = IncomingAttention::Prediction.for_message(message)
      outcome = IncomingAttention::Outcome.label(prediction)
      return _(outcome) if outcome

      state = status(request, event)
      return InfoRequest::State.short_description(state) if state
      return unless IncomingAttention::Effective.active? &&
                    !IncomingAttention::Effective.notification_pending?(
                      message,
                      prediction: prediction
                    )

      decision = IncomingAttention::Effective.decision(message,
                                                       prediction: prediction)
      label = IncomingAttention::Labels.for_message(message,
                                                    decision: decision,
                                                    prediction: prediction)
      _(label) if LABELS.include?(label)
    end

    def self.reply_title(request, event)
      got(request, event, reply_suffix(request, event)) ||
        [_('Reply'), reply_suffix(request, event)].compact.join(' · ')
    end

    def self.got(request, event, suffix)
      state = status(request, event)
      answer = Reply::ANSWERS.key(state)
      if answer && suffix == InfoRequest::State.short_description(state)
        _(Reply::GOT.fetch(answer))
      end
    end

    # Auto-classified routine replies repeat prior status unless overridden.
    def self.status(request, event)
      state = event.calculated_state || event.described_state
      return unless STATUSES.include?(state)
      if Stage.auto_classified_message_ids(request).
         include?(event.incoming_message_id) &&
         !Stage.decision?(request, event)
        return
      end

      state
    end

    # Joins sender and public body name without core's trailing comma.
    def self.sender(request, message)
      names = []
      names << message.safe_from_name if message.specific_from_name?
      names << request.public_body.name if message.from_public_body?
      names.any? ? names.join(', ') : message.safe_from_name
    end

    attr_reader :request

    def initialize(request, ability, documents: [], today: Time.zone.today)
      @request = request
      @ability = ability
      @documents = documents
      @today = today
    end

    def entries
      @entries ||= [*event_entries, *adjustment_entries, *document_entries,
                    *closure_entries].
        each_with_index.sort_by { |entry, index| [entry.at, index] }.
        map(&:first)
    end

    def upcoming(action, reply = nil)
      if last_reply_with_open_review?(action, reply)
        return Entry.new(at: reply.review_by, kind: :ask_review,
                         title: _('Last day to ask for a review'))
      end

      title = upcoming_title(action)
      return unless title
      return if action.late? || action.date.nil? || action.date < @today

      Entry.new(at: action.date,
                kind: action.kind == :ask_review ? :ask_review : :next,
                title: title)
    end

    private

    def body_name
      request.public_body.name
    end

    def event_entries
      events = Stage.events(request)
      events.each_with_index.filter_map do |event, index|
        next unless event.visible?

        case event.event_type
        when 'sent' then sent(event, _('Request sent'))
        when 'resent' then sent(event, _('Request sent again'))
        when 'followup_sent'
          sent(event, follow_up_title(event, events.first(index)))
        when 'followup_resent' then sent(event, _('Follow-up sent again'))
        when 'send_error'
          Entry.new(at: event.created_at,
                    kind: :late,
                    title: _('Couldn’t be delivered'),
                    event: event)
        when 'overdue'
          Entry.new(at: event.created_at,
                    kind: :late,
                    title: _('Response overdue'),
                    event: event)
        when 'response' then reply(event)
        end
      end
    end

    def sent(event, title)
      message = event.outgoing_message
      hidden = message && !@ability.can?(:read, message)

      Entry.new(at: event.created_at,
                kind: hidden ? :hidden : :sent,
                title: title,
                meta: _('You to {{authority}}', authority: body_name),
                event: event)
    end

    def follow_up_title(event, earlier)
      case event.outgoing_message&.what_doing
      when 'internal_review' then _('Internal review requested')
      when 'new_information' then _('Clarification sent')
      else
        clarification?(earlier) ? _('Clarification sent') : _('Follow-up sent')
      end
    end

    # Matches core's InfoRequestEvent#is_clarification?.
    def clarification?(earlier)
      earlier.reverse_each do |event|
        return true if event.described_state == 'waiting_clarification'
        return false if event.event_type == 'followup_sent'
      end
      false
    end

    def reply(event)
      message = event.incoming_message
      return unless message
      return hidden_reply(event) unless @ability.can?(:read, message)

      suffix = self.class.reply_suffix(request, event)
      routine = suffix.in?(IncomingAttention::Labels::ROUTINE.values.
                             map { |label| _(label) }) ||
                (suffix.nil? && IncomingAttention::Effective.active? &&
                 IncomingAttention::Effective.routine?(message))
      answer = Reply.new(request, event, @ability)
      Entry.new(at: message.sent_at || event.created_at,
                kind: routine ? :routine : :reply,
                title: _('Reply from {{sender}}',
                         sender: self.class.sender(request, message)),
                meta: self.class.got(request, event, suffix) || suffix,
                timing: reply_timing(answer, routine),
                line: answer.first_line,
                event: event)
    end

    # Privacy: omit sender, sent_at, and label for hidden replies.
    def hidden_reply(event)
      Entry.new(at: event.created_at,
                kind: :hidden,
                title: _('Reply hidden'),
                event: event)
    end

    def reply_timing(reply, routine)
      return if routine || reply.due.nil?

      reply.late? ? _('Late') : _('On time')
    end

    def adjustment_entries
      Adjustment::STAGES.
        filter_map { |stage| Adjustment.current(request, stage) }.
        map do |change|
          Entry.new(at: change.created_at,
                    kind: :sent,
                    title: _('Due date changed'),
                    meta: _('{{reason}}: {{from}} to {{to}}',
                            reason: change.reason_label,
                            from: Overview.format_date(change.original_due_on),
                            to: Overview.format_date(change.due_on)))
        end
    end

    def document_entries
      published = @documents.select(&:first_published_at).
        group_by { |document| document.first_published_at.to_date }
      withdrawn = @documents.
        select { |document| document.withdrawn? && document.withdrawn_at }.
        group_by { |document| document.withdrawn_at.to_date }
      [
        *published.map do |_, list|
          documents_entry(list, :first_published_at, 'published')
        end,
        *withdrawn.map do |_, list|
          documents_entry(list, :withdrawn_at, 'withdrawn')
        end
      ]
    end

    def documents_entry(list, column, verb)
      title = if verb == 'published'
                n_('Document published',
                   '{{count}} documents published',
                   list.size,
                   count: list.size)
              else
                n_('Document withdrawn',
                   '{{count}} documents withdrawn',
                   list.size,
                   count: list.size)
              end
      Entry.new(at: list.map(&column).min,
                kind: :doc,
                title: title,
                documents: list.sort_by(&column))
    end

    def closure_entries
      closures = if request.association(:deadline_closures).loaded?
                   request.deadline_closures
                 else
                   Closure.where(info_request_id: request.id)
                 end
      closures.map do |closure|
        Entry.new(
          at: closure.created_at,
          kind: :sent,
          title: _('Marked complete'),
          meta: InfoRequest::State.short_description(closure.final_state)
        )
      end
    end

    def last_reply_with_open_review?(action, reply)
      action.kind == :read_reply && !action.late? && reply&.last? &&
        reply.review_open?(@today)
    end

    def upcoming_title(action)
      case action.kind
      when :response then _('Response due')
      when :post then _('Reply by post expected')
      when :review
        action.scottish? ? _('Review due') : _('Internal review due')
      when :ask_review then _('Last day to ask for a review')
      end
    end
  end
end
