module Deadlines
  # The next actions for all of a user's requests, for the dashboard's lists.
  module Overview
    module_function

    def actions(user, today: Time.zone.today)
      requests = requests(user)
      next_actions(requests,
                   attention_messages(requests)&.map(&:info_request_id)&.to_set,
                   today: today).reject(&:none?)
    end

    # Filters via Ability so admin-hidden requests never appear in lists.
    def requests(user)
      ability = Ability.new(user)
      requests = user.info_requests.where.not(described_state: nil).
        includes(:deadline_adjustments,
                 :deadline_closures,
                 :info_request_batch,
                 public_body: [:translations, :tags]).
        select { |request| ability.can?(:read, request) }
      ActiveRecord::Associations::Preloader.new(
        records: requests.select { |request| history_needed?(request) },
        associations: { info_request_events: :outgoing_message }
      ).call
      requests
    end

    def attention_messages(requests)
      return unless IncomingAttention::Effective.active?

      IncomingAttention::Effective.dashboard_attention(
        IncomingMessage.where(info_request_id: requests.map(&:id))
      ).to_a
    end

    def next_actions(requests, attention_ids, today: Time.zone.today)
      ids = requests.map(&:id)
      # Match Stage.auto_classified_message_ids: automatic outcomes count.
      auto_ids = IncomingAttention::Prediction.
        where(info_request_id: ids,
              auto_classified: true,
              outcome_applied_state: nil).
        pluck(:info_request_id, :incoming_message_id).
        group_by(&:first).
        transform_values { |rows| rows.map(&:last).to_set }
      requests.each do |request|
        request.deadlines_auto_classified_ids =
          auto_ids.fetch(request.id, Set.new)
      end
      requests.map do |request|
        NextAction.for(request, today: today, attention_ids: attention_ids)
      end
    end

    # Preload optimization only: skips loading events for simple states when
    # core's dates are present and no closure/adjustment/unread reply applies.
    def history_needed?(request)
      !%w[waiting_response gone_postal successful not_held
          user_withdrawn].include?(request.described_state) ||
        request.awaiting_description? ||
        request.deadline_closures.any?(&:active?) ||
        request.deadline_adjustments.any?(&:active?) ||
        request.read_attribute(:date_response_required_by).nil? ||
        request.read_attribute(:date_very_overdue_after).nil?
    end
    private_class_method :history_needed?

    def lists(user, today: Time.zone.today)
      grouped = actions(user, today: today).group_by(&:group)
      %i[action_required awaiting_authority].to_h do |group|
        [
          group,
          (grouped[group] || []).sort_by do |action|
            [action.date || Date.new(9999), action.request.id]
          end
        ]
      end
    end

    def format_date(date, today = Time.zone.today)
      if date.year == today.year
        date.strftime('%-d %b')
      else
        date.strftime('%-d %b %Y')
      end
    end

    # A batch takes its earliest child's deadline; requests with nothing
    # pending go last, most recently updated first.
    def sort_summaries(summaries, user, today: Time.zone.today)
      by_request = actions(user, today: today).
        index_by { |action| action.request.id }
      keyed = summaries.to_a.map do |summary|
        ids =
          if summary.summarisable_type == 'InfoRequestBatch'
            InfoRequest.where(info_request_batch_id: summary.summarisable_id).
              pluck(:id)
          else
            [summary.summarisable_id]
          end
        date = ids.filter_map { |id| by_request[id]&.date }.min
        [date ? [0, date.jd, 0] : [1, 0, -summary.request_updated_at.to_i],
         summary]
      end
      keyed.sort_by(&:first).map(&:last)
    end
  end
end
