# == Schema Information
#
# Table name: incoming_messages
#
#  id                             :integer          not null, primary key
#  info_request_id                :integer          not null
#  created_at                     :datetime         not null
#  updated_at                     :datetime         not null
#  raw_email_id                   :integer          not null
#  cached_main_body_text_folded   :text
#  cached_main_body_text_unfolded :text
#  subject                        :text
#  from_email_domain              :text
#  valid_to_reply_to              :boolean
#  last_parsed                    :datetime
#  from_name                      :text
#  sent_at                        :datetime
#  prominence                     :string           default("normal"), not null
#  prominence_reason              :text
#  from_email                     :text
#

# Copyright (c) 2007 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

# TODO
# Move some of the (e.g. quoting) functions here into rblib, as they feel
# general not specific to IncomingMessage.

require 'zip'

# An email reply on an InfoRequest, backed by a RawEmail and FoiAttachments.
# Coordinates parsing, body caching, masking, visibility and reader jobs.
class IncomingMessage < ApplicationRecord
  include MessageProminence
  include MaskedByRequest
  include Taggable

  # An IncomingMessage is intrinsically linked to its RawEmail. RawEmail just
  # holds the underlying plain text email and some basic methods for working
  # with it, whereas IncomingMessage coordinates extracting the useful data to
  # our domain records. This concern handles that basic relationship,
  # coordination and caching.
  include IncomingMessage::FromRawEmail

  # These concerns handle the specifics of parsing and working with the main
  # body and other attachments extracted from the RawEmail.
  include IncomingMessage::Attachments
  include IncomingMessage::MainBody

  # Ancillary behaviour
  include IncomingMessage::QuoteHandling
  include IncomingMessage::Refusals

  UnableToExtractAttachments = Class.new(StandardError)

  belongs_to :info_request,
             inverse_of: :incoming_messages,
             counter_cache: true

  has_one :user, through: :info_request

  has_many :outgoing_message_followups,
           inverse_of: :incoming_message_followup,
           foreign_key: 'incoming_message_followup_id',
           class_name: 'OutgoingMessage',
           dependent: :nullify

  # never really has many info_request_events, but could in theory
  has_many :info_request_events,
           dependent: :destroy,
           inverse_of: :incoming_message

  after_destroy :update_request
  after_update :update_request
  after_create :touch_request_activity
  after_update :touch_request_activity, if: :saved_change_to_info_request_id?

  after_create :create_attention_prediction
  after_update :invalidate_attention_prediction
  after_create :store_text_later

  delegate :erased?, :ensure_not_erased!, :kept?,
           to: :raw_email, prefix: :raw_email

  delegate :expire, :log_event, to: :info_request

  # Given that there are in theory many info request events, a convenience
  # method for getting the response event.
  def response_event
    info_request_events.where(event_type: 'response').first
  end

  # Routes follow-ups to the sender only when valid and requester-visible
  # (decided on the reply alone, not the requester's account state).
  def followup_to_sender?
    valid_to_reply_to? && Ability::RequesterVisible.own(self) == :requester
  end

  # Re-checks the no-reply list so later additions block existing replies too.
  def valid_to_reply_to?
    valid_to_reply_to &&
      !ReplyToAddressValidator.invalid_reply_addresses.
        include?(from_email.to_s.downcase)
  end

  def redeliverable?
    raw_email&.kept? == true
  end

  def mask_attachments!
    foi_attachments.not_erased.unmasked.each do |attachment|
      FoiAttachment::MaskJob.perform_now(attachment)
    end
    foi_attachments.reset
  end

  # Public: The display name of the email sender with the associated
  # InfoRequest's censor rules applied.
  #
  # Example:
  #
  #   # Given a CensorRule that redacts the word 'Person':
  #
  #   incoming_message.from_name
  #   # => FOI Person
  #
  #   incoming_message.safe_from_name
  #   # => FOI [REDACTED]
  #
  # Returns a String
  def safe_from_name
    return unless from_name
    unless persisted?
      return apply_censor_rules(from_name, 'text/plain',
                                redacted_attribute: :from_name)
    end

    Current.memo(:safe_from_name, id) do
      apply_censor_rules(from_name, 'text/plain',
                         redacted_attribute: :from_name)
    end
  end

  def safe_subject
    apply_censor_rules(subject, 'text/plain', redacted_attribute: :subject)
  end

  def specific_from_name?
    !safe_from_name.nil? &&
      safe_from_name.strip != info_request.public_body.name.strip
  end

  def from_public_body?
    safe_from_name.nil? ||
      (from_email_domain == info_request.public_body.request_email_domain)
  end

  # This method updates the cached column of the InfoRequest that
  # stores the last created_at date of relevant events
  # when updating an IncomingMessage associated with the request
  def update_request
    info_request.update_last_public_response_at
  end

  # Removes anything cached about the object in the database, and saves
  def clear_in_database_caches!
    self.cached_main_body_text_unfolded = nil
    self.cached_main_body_text_folded = nil
    save!
  end

  def storage_keys
    keys = {}
    keys[:raw_email] = raw_email.storage_key
    keys[:attachments] = foi_attachments.map(&:storage_key)
    keys
  end

  # Called by StoreTextJob after caching text so downstream readers don't race
  # to parse it concurrently; each enqueue is isolated.
  def queue_text_readers
    queue_attention_prediction
    suggest_documents_later
  end

  private

  # A reading not queued here is queued by IncomingAttention::Recovery.
  def queue_attention_prediction
    return unless defined?(IncomingAttention::Prediction)

    IncomingAttention::Prediction.for_message(self)&.enqueue!
  rescue StandardError => e
    Rails.logger.warn(
      "IncomingMessage #{id}: AI reading not queued (#{e.class})"
    )
  end

  def create_attention_prediction
    return unless defined?(IncomingAttention::Prediction)

    IncomingAttention::Prediction.ensure_for(self)
  end

  def invalidate_attention_prediction
    return unless defined?(IncomingAttention::Prediction)
    return unless saved_change_to_info_request_id? ||
                  saved_change_to_raw_email_id? || saved_change_to_prominence?

    IncomingAttention::Prediction.invalidate_message(id, 'visibility_changed')
  end

  # Runs after commit so the stored mail exists; on enqueue failure, falls back
  # to queueing text readers directly rather than failing mail receipt.
  def store_text_later
    ActiveRecord.after_all_transactions_commit do
      IncomingMessage::StoreTextJob.perform_later(self) or raise 'not queued'
    rescue StandardError => e
      Rails.logger.warn(
        "IncomingMessage #{id}: text not queued for storing (#{e.class})"
      )
      queue_text_readers
    end
  end

  def touch_request_activity
    info_request&.record_activity!(Time.current)
  end

  def suggest_documents_later
    return unless defined?(Disclosures::SuggestJob)
    return if info_request&.holding_pen_request?(read_only: true)

    message_id = id
    ActiveRecord.after_all_transactions_commit do
      Disclosures::SuggestJob.perform_later(message_id)
    end
  rescue StandardError => e
    Rails.logger.warn("IncomingMessage #{id}: suggest not queued (#{e.class})")
  end
end
