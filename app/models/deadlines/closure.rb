# == Schema Information
#
# Table name: request_deadline_closures
#
#  id              :bigint           not null, primary key
#  info_request_id :bigint           not null
#  user_id         :bigint
#  basis_event_id  :bigint           not null
#  final_state     :string           not null
#  cleared_at      :datetime
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#

module Deadlines
  # Records "Mark complete" final status to hide a request from deadline lists;
  # lapses automatically if any correspondence occurs afterward.
  class Closure < ApplicationRecord
    include Clearable

    self.table_name = 'request_deadline_closures'
    FINAL_STATES = %w[
      successful
      partially_successful
      rejected
      user_withdrawn
    ].freeze
    REOPENING_EVENTS = %w[
      response
      sent
      resent
      followup_sent
      followup_resent
      send_error
    ].freeze

    belongs_to :info_request, inverse_of: :deadline_closures
    belongs_to :user, optional: true # NULL once the user is deleted
    validates :user, presence: true, on: :create

    validates :final_state, inclusion: { in: FINAL_STATES }

    Stale = Class.new(StandardError)
    UnreadReplies = Class.new(StandardError)

    def self.current(request)
      closure = latest(request)
      closure if closure&.in_force?
    end

    def self.latest(request)
      latest_active(request)
    end

    # Refuses closure while unread or unchecked replies exist, since setting a
    # status would mark them reviewed unseen.
    def self.unread_replies?(request)
      return true if request.awaiting_description?
      return false unless defined?(IncomingAttention::Effective) &&
                          IncomingAttention::Effective.active?

      IncomingAttention::Effective.unresolved(
        IncomingMessage.where(info_request_id: request.id)
      ).exists?
    end

    def self.close!(request, user:, final_state:, last_event_id:)
      unless FINAL_STATES.include?(final_state)
        raise ArgumentError, "#{final_state} is not a final status"
      end

      request.with_lock do
        unless request.info_request_events.maximum(:id) == last_event_id.to_i
          raise Stale
        end
        raise UnreadReplies if unread_replies?(request)

        # Match Classifiable#set_described_state order: event, then state.
        event = request.log_event('status_update',
                                  user_id: user.id,
                                  old_described_state: request.described_state,
                                  described_state: final_state)
        user.increment!(:status_update_count)
        request.set_described_state(final_state, user)
        clear_active!(request)
        create!(info_request: request,
                user: user,
                basis_event_id: event.id,
                final_state: final_state)
      end
    end

    def self.reopen!(request)
      clear_active!(request)
    end

    def in_force?
      active? &&
        Stage.events(info_request).none? do |event|
          event.id > basis_event_id &&
            REOPENING_EVENTS.include?(event.event_type)
        end
    end
  end
end
