require 'digest'

module IncomingAttention
  # Builds and sends summary mail from core's unseen notifications, holding
  # routine-only daily digests until the account's next summary time.
  module Digest
    SECTION_KEYS = %i[
      needs_attention
      routine_updates
      already_reviewed
      other_notices
    ].freeze
    Presentation = Struct.new(:sections, :labels, :notification_ids, :sources,
                              :attention_ids, keyword_init: true)
    SnapshotChanged = Class.new(StandardError)

    module_function

    # Per-pass cache of Ability, predictions, and first response events.
    class Pass
      def initialize(user, notifications)
        @user = user
        @message_ids = notifications.
          filter_map { |row| row.info_request_event.incoming_message_id }.to_set
      end

      def ability
        @ability ||= Ability.new(@user)
      end

      def prediction(message)
        unless @message_ids.include?(message.id)
          return Prediction.for_message(message)
        end

        @predictions ||=
          if Config.enabled?
            Prediction.where(incoming_message_id: @message_ids.to_a).
              index_by(&:incoming_message_id)
          else
            {}
          end
        @predictions[message.id]
      end

      # Core's IncomingMessage#response_event is the message's first response
      # event, which is normally the notification's own.
      def response_event(message, event)
        @first_responses ||= InfoRequestEvent.
          where(incoming_message_id: @message_ids.to_a,
                event_type: 'response').
          group(:incoming_message_id).minimum(:id)
        if @first_responses[message.id] == event.id
          event
        else
          message.response_event
        end
      end
    end

    def current_notifications(user, ids)
      rows = Notification.where(id: ids, user_id: user.id).
        includes(
          info_request_event: [
            :incoming_message, :outgoing_message,
            { info_request: [:user, :info_request_batch] }
          ]
        ).
        order(:created_at, :id).to_a
      # Reuse the already-loaded event.info_request to avoid N+1 reads.
      rows.each do |row|
        event = row.info_request_event
        [event.incoming_message, event.outgoing_message].each do |message|
          if message && message.info_request_id == event.info_request_id
            message.association(:info_request).target = event.info_request
          end
        end
      end
    end

    def readable?(user, notification, ability = Ability.new(user))
      return false unless notification.user_id == user.id

      event = notification.info_request_event
      request = event.info_request
      unless request.user_id == user.id && ability.can?(:read, request)
        return false
      end

      if event.incoming_message_id
        message = event.incoming_message
        return false unless message_readable?(message, request, ability)
      end
      if event.outgoing_message_id
        message = event.outgoing_message
        return false unless message_readable?(message, request, ability)
      end
      event.event_type != 'response' || event.incoming_message_id.present?
    rescue ActiveRecord::RecordNotFound
      false
    end

    def message_readable?(message, request, ability)
      message && message.info_request_id == request.id &&
        ability.can?(:read, message)
    end

    def group_for(request, user, ability = nil)
      batch = request.info_request_batch
      if batch && batch.user_id == user.id &&
         (ability || Ability.new(user)).can?(:read, batch)
        batch
      else
        request
      end
    end

    def authorized!(user, notifications)
      authorize(user, notifications).first
    end

    def authorize(user, notifications)
      ids = notifications.map(&:id)
      unless ids.any? && ids.uniq.length == ids.length &&
             ids.all?(Integer)
        raise SnapshotChanged
      end

      rows = current_notifications(user, ids)
      pass = Pass.new(user, rows)
      unless rows.length == ids.length &&
             rows.all? { |row| readable?(user, row, pass.ability) }
        raise SnapshotChanged
      end

      [rows, pass]
    end

    def presentation(user, notifications, pass = Pass.new(user, notifications))
      notifications = notifications.
        reject { |row| notification_pending?(row, pass) }
      sections = SECTION_KEYS.to_h { |key| [key, {}] }
      labels = {}
      sources = {}
      attention_ids = []
      notifications.each do |notification|
        event = notification.info_request_event
        request = event.info_request
        if event.event_type == 'response'
          message = event.incoming_message
          prediction = pass.prediction(message)
          decision = Effective.decision(message, prediction: prediction)
          attention_ids << notification.id if decision.needs_attention?
          section = section_for(message, decision, prediction, event, pass)
          labels[notification.id] = Labels.for_message(message,
                                                       decision: decision,
                                                       prediction: prediction)
          sources[notification.id] = [event.id, request.id, request.user_id,
                                      message.id, message.info_request_id,
                                      message.prominence]
        else
          section = :other_notices
          labels[notification.id] = nil
        end
        group = group_for(request, user, pass.ability)
        (sections.fetch(section)[group] ||= []) << notification
      end
      Presentation.new(sections: sections,
                       labels: labels,
                       notification_ids: notifications.map(&:id),
                       sources: sources,
                       attention_ids: attention_ids)
    end

    def section_for(message, decision, prediction, event, pass)
      if Effective.reviewed?(message,
                             event: pass.response_event(message, event),
                             prediction: prediction)
        :already_reviewed
      else
        decision.routine? ? :routine_updates : :needs_attention
      end
    end

    def notification_pending?(notification, pass = nil)
      event = notification.info_request_event
      message = event.incoming_message
      event.event_type == 'response' && message &&
        Effective.notification_pending?(
          message,
          prediction: pass ? pass.prediction(message) : :lookup
        )
    end

    def signature(value)
      [
        value.notification_ids,
        value.labels,
        value.sources,
        value.attention_ids,
        value.sections.flat_map do |section, groups|
          groups.map do |group, rows|
            [section, group.class.name, group.id, rows.map(&:id)]
          end
        end
      ]
    end

    def with_account_lock(user_id)
      # Session advisory lock serializes sends per account while keeping SMTP
      # outside any transaction or row lock.
      key = ::Digest::SHA256.
        hexdigest("incoming_attention_notifications:#{user_id}")[0, 16].
        to_i(16)
      key -= 2**64 if key >= 2**63
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        return false if connection.transaction_open?
        unless connection.select_value("SELECT pg_try_advisory_lock(#{key})")
          return false
        end

        begin
          yield
        ensure
          connection.execute("SELECT pg_advisory_unlock(#{key})")
        end
      end
    end

    # Core's User#banned? is ban_text.present?; these are the characters
    # Ruby's blank? treats as space.
    BLANK_BAN_TEXT = '^[\t\n\v\f\r \u0085\u00a0\u1680\u2000-\u200a' \
                     '\u2028\u2029\u202f\u205f\u3000]*$'.freeze

    def send_notifications(frequency)
      cutoff = Time.current
      scope = Notification.
        where(frequency: frequency, seen_at: nil, expired: false).
        where('send_after <= ?', cutoff).outside_holding_pen
      # Closed and banned accounts receive no digest (matches core alerts).
      scope = scope.joins(:user).where(users: { closed_at: nil }).
        where("COALESCE(users.ban_text, '') ~ ?", BLANK_BAN_TEXT)
      due_ids = scope.order(:created_at, :id).pluck(:id, :user_id).
        group_by(&:last)
      sent = false
      due_ids.each do |user_id, rows|
        if send_account(user_id, frequency, cutoff, rows.map(&:first))
          sent = true
        end
      end
      sent
    end

    def send_account(user_id, frequency, cutoff, captured_ids)
      with_account_lock(user_id) do
        user = User.find_by(id: user_id)
        next false unless user

        ids = Notification.where(id: captured_ids,
                                 user_id: user_id,
                                 frequency: frequency,
                                 seen_at: nil,
                                 expired: false).
          where('send_after <= ?', cutoff).order(:created_at, :id).pluck(:id)
        rows = current_notifications(user, ids)
        pass = Pass.new(user, rows)
        notifications = rows.select { |row| readable?(user, row, pass.ability) }
        notifications = Notification.reject_and_mark_expired(notifications)
        notifications = notifications.
          reject { |row| notification_pending?(row, pass) }
        next false if notifications.empty?

        shown = presentation(user, notifications, pass)
        if shown.attention_ids.empty? && shown.sections[:other_notices].empty?
          hold!(user, notifications, frequency)
          next false
        end
        unless deliverable?(user)
          Rails.logger.warn(
            'incoming_attention_notification_recipient_not_allowed'
          )
          next false
        end
        delivery = NotificationMailer.daily_summary(user,
                                                    notifications,
                                                    shown,
                                                    frequency: frequency)
        # Rendered before the final check that the sources are current.
        message = delivery.message
        next false unless message.perform_deliveries && message.to.present?

        current, pass = authorize(user, notifications)
        still_due = Notification.where(id: current.map(&:id),
                                       user_id: user_id,
                                       frequency: frequency,
                                       seen_at: nil,
                                       expired: false).
          where('send_after <= ?', cutoff).pluck(:id)
        unless still_due.sort == current.map(&:id).sort &&
               current.none?(&:expired?)
          raise SnapshotChanged
        end
        unless signature(presentation(user, current, pass)) == signature(shown)
          raise SnapshotChanged
        end

        delivered = delivery.deliver_now
        next false unless delivered && delivery.message.perform_deliveries

        Notification.
          where(id: current.map(&:id), user_id: user_id, seen_at: nil).
          update_all(seen_at: Time.current)
        true
      end
    rescue SnapshotChanged
      false
    rescue StandardError => e
      # Leave notifications unseen on delivery error since mail state is
      # unknown (matches core's sender).
      Rails.logger.warn('incoming_attention_notification_delivery_failed ' \
                        "user_id=#{user_id} #{e.class}")
      false
    end

    # Defer routine-only rows to next_daily_summary_time to merge later.
    def hold!(user, notifications, frequency)
      unless frequency == Notification.frequencies[Notification::DAILY] &&
             Config.enabled?
        return
      end

      Notification.
        where(id: notifications.map(&:id), user_id: user.id, seen_at: nil).
        update_all(send_after: user.next_daily_summary_time)
    end

    # Extension hook for site add-ons enforcing a recipient allowlist.
    def deliverable?(_user)
      true
    end
  end
end
