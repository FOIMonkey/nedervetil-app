module IncomingAttention
  # Notifications and Pro share this read-only importance decision. Stored
  # predictions stay valid across releases; human choices take priority.
  module Effective
    Decision = Struct.new(:bucket, :label, :route, :reason,
                          keyword_init: true) do
      def routine? = bucket == 'routine_updates'
      def needs_attention? = !routine?
    end

    module_function

    def active? = Config.enabled?

    def attention(reason = :uncertain, route = 'REVIEW')
      Decision.new(bucket: 'needs_attention',
                   label: if route == 'ADMIN_SUPPORT'
                            'Delivery support needed'
                          else
                            'Needs attention'
                          end,
                   route: route,
                   reason: reason)
    end

    def decision(message, prediction: :lookup, current: :lookup)
      return attention(:disabled) unless active?

      prediction = Prediction.for_message(message) if prediction == :lookup
      return attention(:missing) unless prediction
      return attention(:human) if prediction.attention_override == 'attention'
      if prediction.attention_override == 'routine'
        return Decision.new(bucket: 'routine_updates', label: 'Routine update',
                            route: 'SKIP', reason: :human)
      end

      return attention(:incomplete) unless prediction.status == 'complete'

      unless prediction.eligible?
        return attention(
          :ineligible,
          prediction.route == 'ADMIN_SUPPORT' ? 'ADMIN_SUPPORT' : 'REVIEW'
        )
      end
      unless current == :lookup ? prediction.current?(message) : current
        return attention(:stale)
      end
      unless %w[SKIP REVIEW ADMIN_SUPPORT].include?(prediction.route) &&
             prediction.needs_check == (prediction.route != 'SKIP')
        return attention(:invalid_route)
      end
      unless prediction.route == 'SKIP'
        return attention(:bounded, prediction.route)
      end

      Decision.new(bucket: 'routine_updates', label: 'Routine update',
                   route: 'SKIP', reason: :bounded)
    rescue StandardError => e
      Rails.logger.warn('incoming_attention_decision_failed ' \
                        "message_id=#{message&.id} #{e.class}")
      attention(:unavailable)
    end

    def routine?(message) = decision(message).routine?

    # New mail gets a prediction before commit; older mail without one is only
    # held if covered by the backfill cutoff.
    def notification_pending?(message, prediction: :lookup)
      return false unless active?

      prediction = Prediction.for_message(message) if prediction == :lookup
      unless prediction
        cutoff = Config.backfill_received_after
        pending = cutoff.present? && message.created_at >= cutoff &&
                  !message.info_request.holding_pen_request?(read_only: true)
        # Recovery makes rows only for unresolved replies, so a resolved one
        # would wait indefinitely.
        return pending && !OptOut.opted_out?(message.info_request.user) &&
               unresolved(IncomingMessage.where(id: message.id)).exists?
      end
      prediction.attention_override.nil? &&
        %w[pending running stale].include?(prediction.status) &&
        !OptOut.opted_out?(message.info_request.user)
    rescue StandardError => e
      Rails.logger.warn('incoming_attention_pending_check_failed ' \
                        "message_id=#{message&.id} #{e.class}")
      false
    end

    # Whether a reply was reviewed comes from core's classification, not from
    # the AI label. It matches the SQL in unresolved.
    def reviewed?(message, event: :lookup, prediction: :lookup)
      event = message.response_event if event == :lookup
      unless event && event.info_request_id == message.info_request_id &&
             event.event_type == 'response'
        return false
      end

      request = message.info_request
      row = prediction == :lookup ? Prediction.for_message(message) : prediction
      return true if row&.human_reviewed_at
      return false if row&.auto_classified?
      return true unless request.awaiting_description?
      return true if event.last_described_at.present?

      request.info_request_events.where.not(described_state: nil).
        exists?(['created_at > ? OR (created_at = ? AND id >= ?)',
                 event.created_at, event.created_at, event.id])
    rescue StandardError => e
      Rails.logger.warn('incoming_attention_review_check_failed ' \
                        "message_id=#{message&.id} #{e.class}")
      false
    end

    # Owner-readable replies via Ability::RequesterVisible; excludes hidden
    # replies even for an admin's own requests.
    def owner_readable_sql
      Ability::RequesterVisible.sql(request: 'iaowner_request',
                                    message: 'incoming_messages')
    end

    def relation(scope = IncomingMessage.all)
      join = 'INNER JOIN info_requests iaowner_request ' \
             'ON iaowner_request.id = incoming_messages.info_request_id'
      scope = scope.joins(join) unless scope.joins_values.include?(join)
      scope.where(owner_readable_sql).
        where.not(iaowner_request: { url_title: 'holding_pen' })
    end

    # The columns decision and notification_pending? read.
    DECISION_COLUMNS = %i[id info_request_id created_at].freeze

    def eligible_ids(scope, route)
      return [] unless active?

      Current.memo(:eligible_ids, route, scope) do
        readable = relation(scope)
        predictions = Prediction.
          where(incoming_message_id: readable.select(:id)).
          index_by(&:incoming_message_id)
        readable.where(id: predictions.keys).select(*DECISION_COLUMNS).
          filter_map do |message|
            value = decision(message, prediction: predictions[message.id])
            if %i[bounded human].include?(value.reason) && value.route == route
              message.id
            end
          end
      end
    end

    def routine(scope = IncomingMessage.all)
      pending = unresolved(scope)
      pending.where(id: eligible_ids(pending, 'SKIP'))
    end

    # Core's status classification decides. An earlier unclassified reply
    # stays unresolved when a later routine one arrives.
    def unresolved(scope = IncomingMessage.all)
      relation(scope).where(<<~SQL.squish)
        NOT EXISTS (SELECT 1 FROM incoming_attention_predictions iahuman
        WHERE iahuman.incoming_message_id = incoming_messages.id
        AND iahuman.human_reviewed_at IS NOT NULL)
        AND (EXISTS (SELECT 1 FROM incoming_attention_predictions iaauto
        WHERE iaauto.incoming_message_id = incoming_messages.id
        AND iaauto.auto_classified = TRUE) OR
        NOT EXISTS (SELECT 1 FROM info_request_events iaclassified
        WHERE iaclassified.incoming_message_id = incoming_messages.id
        AND iaclassified.info_request_id = incoming_messages.info_request_id
        AND iaclassified.event_type = 'response'
        AND (iaowner_request.awaiting_description = FALSE
        OR iaclassified.last_described_at IS NOT NULL OR
        EXISTS (SELECT 1 FROM info_request_events iacoredescription
        WHERE iacoredescription.info_request_id = iaclassified.info_request_id
        AND iacoredescription.described_state IS NOT NULL
        AND (iacoredescription.created_at > iaclassified.created_at
        OR (iacoredescription.created_at = iaclassified.created_at
        AND iacoredescription.id >= iaclassified.id))
        AND NOT EXISTS (SELECT 1 FROM incoming_attention_predictions iap
        WHERE iap.response_event_id = iacoredescription.id
        AND iap.auto_classified = TRUE)))))
      SQL
    end

    def needs_attention(scope = IncomingMessage.all)
      pending = unresolved(scope)
      pending.where.not(id: eligible_ids(pending, 'SKIP'))
    end

    def dashboard_ready(scope = IncomingMessage.all)
      return scope unless active?

      ids = Current.memo(:dashboard_ready, scope) do
        rows = Prediction.where(incoming_message_id: scope.select(:id)).
          index_by(&:incoming_message_id)
        scope.select(*DECISION_COLUMNS).filter_map do |message|
          row = rows[message.id]
          next if notification_pending?(message, prediction: row)
          next if row && row.info_request_id != message.info_request_id

          message.id
        end
      end
      scope.where(id: ids)
    end

    def dashboard_attention(scope = IncomingMessage.all)
      dashboard_ready(needs_attention(scope))
    end

    # The dashboard may show the waiting state while a check runs; once a
    # routine-only thread is classified, core's status applies.
    def dashboard_status(request)
      status = request.calculate_status
      unless active? && status == 'waiting_classification' &&
             !dashboard_attention(
               IncomingMessage.where(info_request_id: request.id)
             ).exists?
        return status
      end

      routine_status(request)
    end

    def routine_status(request)
      state = request.described_state
      return state unless state == 'waiting_response'

      today = Time.zone.today
      very = request.date_very_overdue_after
      due = request.date_response_required_by
      return 'waiting_response_very_overdue' if today > very
      return 'waiting_response_overdue' if today > due

      'waiting_response'
    end

    def summaries_for_requests(summaries, requests)
      ids = requests.select(:id).to_sql
      summaries.where(
        "(request_summaries.summarisable_type = 'InfoRequest' " \
        "AND request_summaries.summarisable_id IN (#{ids})) OR " \
        "(request_summaries.summarisable_type = 'InfoRequestBatch' " \
        "AND EXISTS (SELECT 1 FROM info_requests iachild WHERE " \
        "iachild.info_request_batch_id = request_summaries.summarisable_id " \
        "AND iachild.id IN (#{ids})))"
      )
    end

    # Scopes to user's own requests unless requests is passed (admins may see
    # passed requests); returns none when user is nil.
    def visible_requests(user, requests = nil)
      return InfoRequest.none unless user

      requests ||= InfoRequest.where(user_id: user.id)
      return requests if Ability.new(user).can?(:admin, InfoRequest)

      requests.where(user_id: user.id).
        where(Ability::RequesterVisible.sql(request: 'info_requests'))
    end

    def visible_summaries(summaries, user)
      return summaries.none unless user
      return summaries if Ability.new(user).can?(:admin, InfoRequest)

      summaries.where(
        "request_summaries.summarisable_type <> 'InfoRequest' OR " \
        'EXISTS (SELECT 1 FROM info_requests vis_req ' \
        'WHERE vis_req.id = request_summaries.summarisable_id ' \
        'AND vis_req.prominence IN (?))',
        Ability::RequesterVisible::REQUEST
      )
    end

    def ready_request_ids(requests)
      Current.memo(:ready_request_ids, requests) do
        dashboard_attention(
          IncomingMessage.where(info_request_id: requests.select(:id))
        ).distinct.pluck(:info_request_id)
      end
    end

    def summaries(summaries, bucket, user: nil)
      requests = visible_requests(user)
      if bucket.to_sym == :needs_attention
        return summaries_for_requests(
          summaries,
          InfoRequest.where(id: ready_request_ids(requests))
        )
      end

      messages = public_send(
        bucket,
        IncomingMessage.where(info_request_id: requests.select(:id))
      )
      summaries_for_requests(
        summaries,
        InfoRequest.where(id: messages.select(:info_request_id))
      )
    end

    def phase_summaries(summaries, phase, user: nil)
      requests = visible_requests(user)
      phase_s = phase.to_s
      if active? &&
         %w[response_received awaiting_response overdue very_overdue].
           include?(phase_s)
        ready_ids = ready_request_ids(requests)
        requests = phase_requests(requests, phase_s, ready_ids)
      else
        requests = requests.public_send(phase)
      end
      relevant = summaries_for_requests(summaries, requests)
      return relevant unless phase_s == 'awaiting_response'

      unsent = InfoRequestBatch.where(sent_at: nil).select(:id)
      relevant.or(summaries.where(summarisable_type: 'InfoRequestBatch',
                                  summarisable_id: unsent))
    end

    def phase_requests(requests, phase_s, ready_ids)
      return requests.where(id: ready_ids) if phase_s == 'response_received'

      waiting = requests.where(described_state: 'waiting_response').
        where.not(id: ready_ids)
      today = Time.zone.today
      case phase_s
      when 'awaiting_response'
        waiting.where('date_response_required_by >= ?', today)
      when 'overdue'
        waiting.where('date_response_required_by < ? AND ' \
                      'date_very_overdue_after >= ?', today, today)
      when 'very_overdue'
        waiting.where('date_very_overdue_after < ?', today)
      end
    end

    def counts(user)
      req_ids = visible_requests(user).select(:id)
      pending = unresolved(IncomingMessage.where(info_request_id: req_ids))
      routine_ids = eligible_ids(pending, 'SKIP')
      { 'needs_attention' =>
          dashboard_ready(pending.where.not(id: routine_ids)).count,
        'routine_updates' => pending.where(id: routine_ids).count }
    end

    def checked(messages)
      predictions = Prediction.where(incoming_message_id: messages.map(&:id)).
        index_by(&:incoming_message_id)
      ready = messages.select do |message|
        row = predictions[message.id]
        (!row || row.info_request_id == message.info_request_id) &&
          !notification_pending?(message, prediction: row)
      end
      [ready, predictions]
    end

    InboxReply = Struct.new(:message, :request, :label, :routine) do
      def received_at = message[:sent_at] || message.created_at
    end

    def inbox(user)
      requests = visible_requests(user, user.info_requests).
        includes(:info_request_batch, public_body: :translations).index_by(&:id)
      messages =
        unresolved(IncomingMessage.where(info_request_id: requests.keys)).
          order('incoming_messages.sent_at DESC NULLS LAST',
                'incoming_messages.id DESC').to_a
      ready, predictions = checked(messages)
      replies = ready.map do |message|
        pred = predictions[message.id]
        verdict = decision(message, prediction: pred, current: true)
        label = Labels.for_message(message, decision: verdict,
                                            prediction: pred, current: true)
        InboxReply.new(message, requests.fetch(message.info_request_id),
                       label, verdict.routine?)
      end
      { attention: replies.reject(&:routine),
        routine: replies.select(&:routine),
        checking: messages.size - ready.size }
    end

    def page_data(summaries, user: nil)
      singles = summaries.select { |s| s.summarisable_type == 'InfoRequest' }.
        map(&:summarisable_id)
      batches = summaries.
        select { |s| s.summarisable_type == 'InfoRequestBatch' }.
        map(&:summarisable_id)
      requests = visible_requests(
        user,
        InfoRequest.where(id: singles).
          or(InfoRequest.where(info_request_batch_id: batches))
      ).includes(public_body: :translations).order(:id).to_a
      messages = unresolved(
        IncomingMessage.where(info_request_id: requests.map(&:id))
      ).order('incoming_messages.sent_at ASC NULLS LAST',
              'incoming_messages.id ASC').to_a
      messages, predictions = checked(messages)
      decisions = messages.to_h do |m|
        [m.id, decision(m, prediction: predictions[m.id], current: true)]
      end
      grouped = messages.group_by(&:info_request_id)
      labels = messages.to_h do |m|
        [m.id, Labels.for_message(m, decision: decisions.fetch(m.id),
                                     prediction: predictions[m.id],
                                     current: true)]
      end
      by_group = requests.group_by do |r|
        r.info_request_batch_id || "request:#{r.id}"
      end
      { requests: by_group,
        messages: grouped,
        message_counts: grouped.transform_values(&:size),
        decisions: decisions,
        labels: labels,
        bucket_counts: grouped.transform_values do |items|
          items.partition { |m| decisions.fetch(m.id).needs_attention? }.
            map(&:size)
        end }
    end
  end
end
