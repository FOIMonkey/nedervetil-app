# == Schema Information
#
# Table name: info_request_events
#
#  id                  :integer          not null, primary key
#  info_request_id     :integer          not null
#  event_type          :text             not null
#  created_at          :datetime         not null
#  described_state     :string
#  calculated_state    :string
#  last_described_at   :datetime
#  incoming_message_id :integer
#  outgoing_message_id :integer
#  updated_at          :datetime
#  params              :jsonb
#

# Copyright (c) 2007 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

# Audit and timeline entry on an InfoRequest recording sends, replies, status
# changes and admin actions, with JSONB params and admin-only search indexing.
class InfoRequestEvent < ApplicationRecord
  include Searchable

  EVENT_TYPES = [
    'sent',
    'resent',
    'followup_sent',
    'followup_resent',
    'edit', # title etc. edited (in admin interface)
    'edit_outgoing', # outgoing message edited (in admin interface)
    'destroy_comment', # deleted a comment (in admin interface) (retired)
    'edit_comment', # comment edited (in admin interface) (retired)
    'hide_comment', # comment hidden by admin (retired)
    'report_comment', # comment reported for admin attention by user (retired)
    'report_request', # a request reported for admin attention by user
    'destroy_incoming', # deleted an incoming message (in admin interface)
    'destroy_outgoing', # deleted an outgoing message (in admin interface)
    # rubocop:disable Layout/LineLength -- each entry has a trailing comment
    'redeliver_incoming', # redelivered an incoming message elsewhere (in admin interface)
    # rubocop:enable Layout/LineLength
    'edit_incoming', # incoming message edited (in admin interface)
    'edit_attachment', # attachment edited (in admin interface)
    'erase_raw_email', # Erase underlying response data
    'erase_attachment', # erase underlying attachment data
    'move_request', # changed user or public body (in admin interface)
    'hide', # hid a request (in admin interface)
    'manual', # you did something in the db by hand
    'response', # an incoming message is received
    'comment', # an annotation was added (retired)
    'status_update', # someone updates the status of the request
    'overdue', # the request becomes overdue
    'very_overdue', # the request becomes very overdue
    'embargo_expiring', # an embargo was about to expire (retired)
    'expire_embargo', # an embargo on the request expired (retired)
    'set_embargo', # an embargo was added or extended (retired)
    'send_error', # an error during sending
    'refusal_advice', # the results of completing the refusal advice wizard
    'public_token' # a share-by-link token was made or removed (retired)
  ].freeze

  belongs_to :info_request,
             inverse_of: :info_request_events

  belongs_to :outgoing_message,
             inverse_of: :info_request_events,
             optional: true
  belongs_to :incoming_message,
             inverse_of: :info_request_events,
             optional: true

  has_one :request_classification,
          inverse_of: :info_request_event

  has_many :user_info_request_sent_alerts,
           inverse_of: :info_request_event,
           dependent: :destroy
  has_many :notifications,
           inverse_of: :info_request_event,
           dependent: :destroy

  validates_presence_of :event_type

  after_create :update_request, if: :response?

  after_commit -> { info_request.create_or_update_request_summary },
                  on: [:create]

  validates_inclusion_of :event_type, in: EVENT_TYPES

  # user described state (also update in info_request)
  validate :must_be_valid_state

  EVENT_TYPES.each do |event_type|
    scope "#{event_type}_events", -> { where(event_type: event_type) }
  end

  # we don't want users to find events, they search through requests
  # and messages directly. This is only intended for admins to find PII
  # inside the JSON logs.
  searchable admin_index: {
               # call a custom SQL function to extract the relevant bits of
               # JSON into the index, to help keep the index size manageable.
               # Doing this in SQL is a lot faster than doing the same in ruby.
               "cleanup_jsonb_for_search(params)": "A"
             },
             root: :info_request

  # TODO: Can possibly be made private
  # Legacy comment events are hidden (comments removed; see doc/FORK.md).
  def visible?
    event_type != 'comment'
  end

  def params=(new_params)
    super(params_for_jsonb(new_params))
    @memoized_params = nil
    @memoized_params_source = nil

    # TODO: should really set these explicitly, and stop storing them in
    # here, but keep it for compatibility with old way for now
    if params[:incoming_message].is_a?(IncomingMessage)
      self.incoming_message = params[:incoming_message]
    end
    if params[:outgoing_message].is_a?(OutgoingMessage) # rubocop:disable Style/GuardClause -- matches the if above
      self.outgoing_message = params[:outgoing_message]
    end
  end

  # A hash to lazy load Global ID reference models
  class Params < Hash
    def [](key)
      value = super
      return value unless value.is_a?(Hash) && value[:gid]
      return located[key] if located.key?(key)

      located[key] = GlobalID::Locator.locate(value[:gid])
    rescue ActiveRecord::RecordNotFound
      located[key] = value[:gid]
    end

    def []=(key, value)
      located.delete(key)
      super
    end

    def delete(key)
      located.delete(key)
      super
    end

    def clear
      located.clear
      super
    end

    private

    def initialize_copy(_other)
      super
      @located = @located&.dup
    end

    def located
      @located ||= {}
    end
  end

  def params
    params_jsonb = super
    unless params_jsonb
      @memoized_params = nil
      @memoized_params_source = nil
      return
    end
    return @memoized_params if @memoized_params_source.equal?(params_jsonb)

    @memoized_params_source = params_jsonb
    @memoized_params = Params[params_jsonb.deep_symbolize_keys]
  end

  def params_diff
    # split out parameters into old/new diffs, and other ones
    old_params = {}
    new_params = {}
    other_params = {}
    ignore = {}
    params.each do |key, value|
      key = key.to_s
      new_key = key[/^old_(.*)$/, 1]&.to_sym
      if new_key
        if params[new_key] == value
          ignore[new_key] = ''
        else
          old_params[new_key] = value
        end
      elsif params.include?(("old_" + key).to_sym)
        new_params[key.to_sym] = value
      else
        other_params[key.to_sym] = value
      end
    end
    new_params.delete_if { |key, _value| ignore.key?(key) }
    { new: new_params, old: old_params, other: other_params }
  end

  def is_incoming_message?
    incoming_message_id? or (incoming_message if new_record?)
  end

  def is_outgoing_message?
    outgoing_message_id? or (outgoing_message if new_record?)
  end

  def resets_due_dates?
    is_request_sending? || is_clarification?
  end

  def is_request_sending?
    %w[sent resent].include?(event_type) ||
      (event_type == 'send_error' &&
       outgoing_message.message_type == 'initial_request')
  end

  def is_clarification?
    waiting_clarification = false
    # A follow up is a clarification only if it's the first
    # follow up when the request is in a state of
    # waiting for clarification
    previous_events(reverse: true).each do |event|
      if event.described_state == 'waiting_clarification'
        waiting_clarification = true
        break
      end
      break if event.event_type == 'followup_sent'
    end
    waiting_clarification && event_type == 'followup_sent'
  end

  # Public: Checks to see if any subsequent event now resets due dates
  # on the request and resets them if so
  def recheck_due_dates
    subsequent_events.each do |event|
      info_request.update_due_dates(event) if event.resets_due_dates?
    end
  end

  # Display version of status
  def display_status
    if is_incoming_message?
      status = calculated_state
      # rubocop:disable Layout/LineLength -- a return with a ternary
      return status.nil? ? _("Response") : InfoRequest.get_status_description(status)
      # rubocop:enable Layout/LineLength
    end

    if is_outgoing_message?
      status = calculated_state
      if status
        return _("Internal review request") if status == 'internal_review'
        return _("Clarification") if status == 'waiting_response'

        raise _("unknown status {{status}}", status: status)
      end
      # TRANSLATORS: "Follow up" in this context means a further
      # message sent by the requester to the authority after
      # the initial request
      return _("Follow up")
    end

    raise _("display_status only works for incoming and outgoing messages " \
            "right now")
  end

  def is_sent_sort?
    %w[sent resent].include?(event_type)
  end

  def is_followup_sort?
    %w[followup_sent followup_resent].include?(event_type)
  end

  def outgoing?
    %w[sent followup_sent].include?(event_type)
  end

  def response?
    event_type == 'response'
  end

  # This method updates the cached column of the InfoRequest that
  # stores the last created_at date of relevant events
  # when saving or destroying an InfoRequestEvent associated with the request
  def update_request
    info_request.update_last_public_response_at
  end

  def same_email_as_previous_send?
    prev_addr = info_request.get_previous_email_sent_to(self)
    curr_addr = params[:email]
    return true if prev_addr.nil? && curr_addr.nil?
    return false if prev_addr.nil? || curr_addr.nil?

    MailHandler.address_from_string(prev_addr) ==
      MailHandler.address_from_string(curr_addr)
  end

  def set_calculated_state!(state)
    return if calculated_state == state

    self.calculated_state = state
    self.last_described_at = Time.zone.now
    save!
  end

  def foi_attachment
    return unless params[:attachment_id]

    @foi_attachment ||= FoiAttachment.find(params[:attachment_id])
  end

  private

  def previous_events(opts = {})
    order = opts[:reverse] ? 'created_at DESC' : 'created_at'
    self.
      class.
        where(info_request_id: info_request_id).
          where('created_at < ?', created_at).
            order(order)
  end

  def subsequent_events(opts = {})
    order = opts[:reverse] ? 'created_at DESC' : 'created_at'
    self.
      class.
        where(info_request_id: info_request_id).
          where('created_at > ?', created_at).
            order(order)
  end

  def params_for_jsonb(params)
    params.inject({}) do |memo, (k, v)|
      key = k.to_s

      # look for keys ending in `_id` and attempt to map to a Ruby class
      key = key.sub(/_id$/, '')
      if Regexp.last_match
        klass = model_for(key.classify)
        if klass
          # attempt to load the object by ID
          object = klass.find_by(id: v)

          # if object can't be loading, eg, deleted from DB, manually build
          # ID/type hash
          value = { gid: "gid://app/#{klass}/#{v}" } unless object

        else
          # without a class, probably not a application model, EG email message
          # ID, so revert the change to the key to re-add the `_id`
          key = k
        end
      end

      object ||= v if v.is_a?(ApplicationRecord)
      if object
        # if we have an object, map to a ID/type hash - including version if
        # present
        value = { gid: object.to_global_id.to_s }
        value[:version] = object.version if object.respond_to?(:version)
      end

      memo[key.to_sym] = value || v
      memo
    end
  end

  def model_for(klass_str)
    klass = klass_str.safe_constantize
    klass ||= "AlaveteliPro::#{klass_str}".safe_constantize
    klass ||= InfoRequest if klass_str == 'Request'
    klass
  end

  def must_be_valid_state
    if described_state && !InfoRequest::State.all.include?(described_state)
      errors.add(:described_state, "is not a valid state")
    end
  end
end
