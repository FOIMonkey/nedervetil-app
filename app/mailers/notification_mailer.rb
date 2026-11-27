# Copyright (c) 2017 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

# Sends instant and daily-digest Notification emails, integrating with
# IncomingAttention and routing holding-pen replies immediately to admins.
class NotificationMailer < ApplicationMailer
  def self.send_daily_notifications
    frequency = Notification.frequencies[Notification::DAILY]
    held = send_holding_pen_notifications(frequency)
    if IncomingAttention::Config.enabled?
      return IncomingAttention::Digest.send_notifications(frequency) || held
    end

    done_something = false
    notifications = Notification.daily.unseen.where(expired: false).
      outside_holding_pen
    due = notifications.where('send_after <= ?', Time.zone.now)
    due.distinct.pluck(:user_id).each do |user_id|
      done_something = true if deliver_daily_for_user(notifications, user_id)
    end
    held || done_something
  end

  def self.deliver_daily_for_user(notifications, user_id)
    rows = Notification.reject_and_mark_expired(
      notifications.where(user_id: user_id).order(created_at: :desc).to_a
    )
    return false if rows.empty?

    user = User.find_by(id: user_id)
    unless user&.active? && user.receive_email_alerts?
      Notification.where(id: rows.map(&:id)).update_all(expired: true)
      return false
    end

    NotificationMailer.daily_summary(user, rows).deliver_now
    Notification.where(id: rows.map(&:id)).update_all(seen_at: Time.zone.now)
    true
  rescue StandardError => e
    # The rows stay unseen, and the other accounts still get their mail.
    Rails.logger.warn(
      "notification_delivery_failed user_id=#{user_id} #{e.class}"
    )
    false
  end
  private_class_method :deliver_daily_for_user

  def self.send_instant_notifications
    frequency = Notification.frequencies[Notification::INSTANTLY]
    held = send_holding_pen_notifications(frequency)
    if IncomingAttention::Config.enabled?
      return IncomingAttention::Digest.send_notifications(frequency) || held
    end

    done_something = false
    notifications = Notification.instantly.unseen.where(expired: false).
      outside_holding_pen.order(:created_at)
    rows = Notification.reject_and_mark_expired(notifications.to_a)
    rows.each do |notification|
      unless notification.user&.active? &&
             notification.user.receive_email_alerts?
        notification.update!(expired: true)
        next
      end

      NotificationMailer.instant_notification(notification).deliver_now
      notification.update!(seen_at: Time.zone.now)
      done_something = true
    rescue StandardError => e
      Rails.logger.warn(
        "notification_delivery_failed notification_id=#{notification.id} " \
        "#{e.class}"
      )
    end
    held || done_something
  end

  # Delivers holding-pen replies immediately via RequestMailer.new_response;
  # restricted to the hidden holding pen owned by the internal admin user.
  private_class_method def self.send_holding_pen_notifications(frequency)
    sent = false
    notifications = Notification.
      where(frequency: frequency, seen_at: nil, expired: false).
      joins(info_request_event: :info_request).
      where(info_requests: { url_title: 'holding_pen' })
    notifications.order(:id).each do |notification|
      IncomingAttention::Digest.with_account_lock(notification.user_id) do
        notification.reload
        next if notification.seen_at || notification.expired?

        event = notification.info_request_event
        request = event.info_request
        message = event.incoming_message
        next unless holding_pen_response?(notification, event, request, message)

        delivery = RequestMailer.new_response(request, message)
        next unless delivery.message.perform_deliveries &&
                    delivery.message.to.present?

        delivery.deliver_now
        notification.update_columns(seen_at: Time.current)
        sent = true
      end
    rescue StandardError => e
      Rails.logger.warn('incoming_attention_holding_pen_alert_failed ' \
                        "notification_id=#{notification.id} #{e.class}")
    end
    sent
  end

  private_class_method def self.holding_pen_response?(notification, event,
                                                      request, message)
    request.prominence == 'hidden' &&
      request.user_id == User.internal_admin_user.id &&
      notification.user_id == request.user_id &&
      event.event_type == 'response' &&
      message && message.info_request_id == request.id
  end

  def self.send_notifications
    sent_instant_notifications = send_instant_notifications
    sent_daily_notifications = send_daily_notifications
    sent_instant_notifications || sent_daily_notifications
  end

  # A presentation comes only from Digest.send_account, with the rows it
  # groups, and that method checks them again after this renders.
  def daily_summary(user, notifications, presentation = nil,
                    frequency: Notification.frequencies[Notification::DAILY])
    fresh, pass = IncomingAttention::Digest.authorize(user, notifications)
    if IncomingAttention::Config.enabled?
      unless presentation
        notifications = fresh.reject do |row|
          IncomingAttention::Digest.notification_pending?(row, pass)
        end
        return if notifications.empty?

        presentation = IncomingAttention::Digest.presentation(
          user, notifications, pass
        )
      end
    else
      notifications = fresh
      presentation = nil
    end

    @user = user
    @summary = IncomingAttention::Summary.new(user, notifications, presentation)
    @summary_instant =
      frequency == Notification.frequencies[Notification::INSTANTLY]
    summary = @summary
    mail_user(user, subject: -> { summary.subject })
  end

  def instant_notification(notification)
    notification = summarise(notification)
    return unless notification

    event_type = notification.info_request_event.event_type
    method = :"#{event_type}_notification"
    send(method, notification)
  end

  def response_notification(notification)
    notification = summarise(notification) unless @summary
    return unless notification

    @info_request = notification.info_request_event.info_request
    @incoming_message = notification.info_request_event.incoming_message

    mail_user(
      @info_request.user,
      subject: -> {
        _("New response to your FOI request - {{request_title}}",
          request_title: @info_request.title)
      },
      template_name: 'response_notification'
    )
  end

  def overdue_notification(notification)
    @info_request = notification.info_request_event.info_request
    return unless Ability.new(@info_request.user).can?(:read, @info_request)

    @url = signin_url(r: respond_to_last_path(@info_request))

    mail_user(
      @info_request.user,
      subject: -> {
        _(
          "Delayed response to your FOI request - {{request_title}}",
          request_title: @info_request.title
        )
      },
      template_name: 'overdue_notification'
    )
  end

  def very_overdue_notification(notification)
    @info_request = notification.info_request_event.info_request
    return unless Ability.new(@info_request.user).can?(:read, @info_request)

    @url = signin_url(r: respond_to_last_path(@info_request))

    mail_user(
      @info_request.user,
      subject: -> {
        _(
          "You're long overdue a response to your FOI request " \
          "- {{request_title}}",
          request_title: @info_request.title
        )
      },
      template_name: 'very_overdue_notification'
    )
  end

  def mail_user(user, subject:, **options)
    return super unless @summary

    summary = @summary
    super(user, subject: -> { summary.subject }, **options)
  end

  private

  # The notification as it is now, or nil while its reply is still being
  # read. Raises SnapshotChanged if its user may no longer read it.
  def summarise(notification)
    notification = IncomingAttention::Digest.
      authorized!(notification.user, [notification]).first
    if IncomingAttention::Config.enabled? &&
       IncomingAttention::Digest.notification_pending?(notification)
      return
    end

    @summary = IncomingAttention::Summary.new(notification.user, [notification])
    notification
  end
end
