# == Schema Information
#
# Table name: request_deadline_reminders
#
#  id                  :bigint           not null, primary key
#  info_request_id     :bigint           not null
#  outgoing_message_id :bigint
#  user_id             :bigint
#  stage               :string           not null
#  due_on              :date             not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#

module Deadlines
  # Manual overdue follow-up reminder: at most one per due date and once per
  # week (SPACING), exempt from RequestLimits.
  class Reminder < ApplicationRecord
    self.table_name = 'request_deadline_reminders'
    STAGES = %w[response review].freeze
    SPACING = 7.days

    belongs_to :info_request
    belongs_to :outgoing_message, optional: true
    belongs_to :user, optional: true
    validates :stage, inclusion: { in: STAGES }
    validates :due_on, presence: true

    Failed = Class.new(StandardError)
    NothingLate = Class.new(StandardError)

    def self.for(request, stage, due_on)
      return unless due_on && STAGES.include?(stage.to_s)

      find_by(info_request_id: request.id, stage: stage.to_s, due_on: due_on)
    end

    def self.recent(request)
      where(info_request_id: request.id, created_at: SPACING.ago..).
        order(:created_at).last
    end

    def self.among(reminders, stage, due_on)
      cutoff = SPACING.ago
      reminders.find do |reminder|
        reminder.stage == stage.to_s && reminder.due_on == due_on
      end ||
        reminders.select { |reminder| reminder.created_at >= cutoff }.
          max_by { |reminder| [reminder.created_at, reminder.id] }
    end

    # Creates under request lock (backed by unique index) before SMTP delivery;
    # destroys the reminder record if delivery fails.
    def self.send!(request, user)
      message = nil
      reminder = request.with_lock do
        action = NextAction.for(request)
        raise NothingLate unless action.remindable?

        message = OutgoingMessage.new(info_request: request,
                                      message_type: 'followup',
                                      status: 'ready',
                                      what_doing: 'normal_sort',
                                      body: text(request, action))
        message.request_limits_exempt = true
        message.save!
        create!(info_request: request,
                outgoing_message: message,
                user: user,
                stage: action.kind.to_s,
                due_on: action.date)
      end
      begin
        deliver(message)
      rescue Failed
        reminder.destroy!
        raise
      end
      reminder
    rescue ActiveRecord::RecordNotUnique
      raise NothingLate
    end

    def self.text(request, action)
      values = {
        review: action.review_word,
        title: request.title,
        since: long(action.basis_date),
        due: long(action.date),
        public_body_name: request.public_body.name
      }
      chase = if action.kind == :review
                PlainTextTranslation._(
                  "I haven't yet had the result of the {{review}} of my " \
                  "request \"{{title}}\", which I asked for on {{since}}. " \
                  'It was due by {{due}}.', values
                )
              else
                PlainTextTranslation._(
                  "I haven't yet had a reply to my request \"{{title}}\", " \
                  'sent on {{since}}. It was due by {{due}}.', values
                )
              end
      <<~TEXT
        #{PlainTextTranslation._('Dear {{public_body_name}},', values)}

        #{chase}

        #{PlainTextTranslation._('Please reply as soon as you can.')}

        #{PlainTextTranslation._('Yours faithfully,')}

        #{request.user.name}
      TEXT
    end

    def self.long(date)
      I18n.l(date, format: '%-d %B %Y')
    end

    def self.deliver(message)
      raise Failed unless message.sendable?

      begin
        mail = OutgoingMailer.followup(message.info_request, message, nil).
          deliver_now
      rescue *OutgoingMessage.expected_send_errors => e
        message.record_email_failure(e.message)
        raise Failed
      end
      message.record_email_delivery(mail.to_addrs.join(', '), mail.message_id)
      message.info_request.reopen_to_new_responses
    end
  end
end
