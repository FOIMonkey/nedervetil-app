module Deadlines
  # The events a request's deadlines count from, and the due dates that core
  # doesn't keep.
  module Stage
    module_function

    def events(request)
      Piles::Batch.for(request)&.load_events
      request.info_request_events.to_a.sort_by(&:id)
    end

    # Preloads and shares a thread's replies, attachments, events, and
    # predictions once per request page. Returns the replies.
    def share_thread(request)
      messages = request.incoming_messages.to_a
      return messages if request.thread_shared

      ActiveRecord::Associations::Preloader.new(
        records: messages,
        associations: [:raw_email,
                       { foi_attachments: [:applied_revisions,
                                           { file_attachment: :blob }] }]
      ).call
      messages.flat_map(&:foi_attachments).each do |part|
        part.association(:info_request).target = request
      end
      by_id = messages.index_by(&:id)
      outgoing = request.outgoing_messages.to_a.index_by(&:id)
      events(request).each do |event|
        message = by_id[event.incoming_message_id]
        event.association(:incoming_message).target = message if message
        sent = outgoing[event.outgoing_message_id]
        event.association(:outgoing_message).target = sent if sent
      end
      if defined?(IncomingAttention::Prediction)
        IncomingAttention::Prediction.remember_for(by_id.keys)
      end
      request.thread_shared = true
      messages
    end

    # Core raises RuntimeError when a request has no sent message yet.
    def response_basis(request)
      id = request.read_attribute(:last_event_forming_initial_request_id)
      (id && events(request).find { |event| event.id == id }) ||
        request.last_event_forming_initial_request
    rescue RuntimeError
      nil
    end

    # First successful send of the latest internal review request; resending an
    # already-sent review does not restart the clock.
    def review_basis(request)
      sends = events(request).select do |event|
        %w[followup_sent followup_resent].include?(event.event_type) &&
          event.outgoing_message&.what_doing == 'internal_review'
      end
      latest = sends.last or return
      sends.find do |event|
        event.outgoing_message_id == latest.outgoing_message_id
      end
    end

    def basis_event(request, stage)
      case stage
      when 'review' then review_basis(request)
      when 'review_request' then decision_response(request)
      else response_basis(request)
      end
    end

    OUTCOMES = %w[
      successful
      partially_successful
      rejected
      not_held
      user_withdrawn
    ].freeze

    def review_response(request, review = review_basis(request))
      return unless review

      events(request).reverse.find do |event|
        event.id > review.id && decision?(request, event)
      end
    end

    def decision_response(request, review = review_basis(request))
      events(request).reverse.find do |event|
        decision?(request, event) && (!review || event.id < review.id)
      end
    end

    # Auto-classified routine replies repeat the prior status and only count as
    # a decision if followed by a manual status_update (excluding reports and
    # report reverts). Automatic Outcome classifications count as decisions.
    def decision?(request, event)
      return false unless event.event_type == 'response'
      unless OUTCOMES.include?(event.calculated_state || event.described_state)
        return false
      end
      unless auto_classified_message_ids(request).
             include?(event.incoming_message_id)
        return true
      end

      later = events(request).select { |other| other.id > event.id }
      next_reply = later.find { |other| other.event_type == 'response' }
      later.any? do |other|
        manual_status_update?(other) &&
          (!next_reply || other.id < next_reply.id)
      end
    end

    def manual_status_update?(other)
      other.event_type == 'status_update' &&
        InfoRequest::REPORTED_STATES.exclude?(other.described_state) &&
        other.params&.dig(:report_event_id).nil?
    end

    def auto_classified_message_ids(request)
      return Set.new unless defined?(IncomingAttention::Prediction)

      request.deadlines_auto_classified_ids ||=
        IncomingAttention::Prediction.
          where(info_request_id: request.id,
                auto_classified: true,
                outcome_applied_state: nil).
          pluck(:incoming_message_id).to_set
    end

    def computed_due_on(request, stage)
      regime = Deadlines.regime(request)
      case stage
      when 'review'
        basis = review_basis(request) or return
        Calendar.working_days_after(basis.created_at,
                                    Deadlines.review_days.fetch(regime, 20),
                                    regime)
      when 'review_request'
        basis = decision_response(request) or return
        Calendar.working_days_after(review_window_start(request, basis, regime),
                                    Deadlines.review_request_days,
                                    regime)
      else
        request.date_response_required_by
      end
    end

    # FOISA s.20(5) counts from the due date if replied on time, else from the
    # reply; other regimes always count from the reply.
    def review_window_start(request, decision, regime)
      replied = decision.created_at.to_date
      return replied unless regime == 'foisa'

      [replied, request.date_response_required_by].compact.max
    end
  end
end
