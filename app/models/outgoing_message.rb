# == Schema Information
#
# Table name: outgoing_messages
#
#  id                           :integer          not null, primary key
#  info_request_id              :integer          not null
#  body                         :text             not null
#  status                       :string           not null
#  message_type                 :string           not null
#  created_at                   :datetime         not null
#  updated_at                   :datetime         not null
#  last_sent_at                 :datetime
#  incoming_message_followup_id :integer
#  what_doing                   :string           not null
#  prominence                   :string           default("normal"), not null
#  prominence_reason            :text
#  from_name                    :text
#

# Copyright (c) 2007 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

# An initial request or follow-up from a requester to an authority. Validates
# letter templates, applies display/index masking and tracks delivery.
class OutgoingMessage < ApplicationRecord
  include MessageProminence
  include Rails.application.routes.url_helpers
  include LinkToHelper
  include MaskedByRequest
  include Searchable
  include Taggable

  include OutgoingMessage::DeliveryStatus
  include OutgoingMessage::DeliveryTransitions

  MESSAGE_TYPES = %w(initial_request followup).freeze
  WHAT_DOING_VALUES = %w(normal_sort
                         internal_review
                         external_review
                         new_information).freeze

  # To override the default letter (default_letter= is defined below)
  attr_reader :default_letter

  before_validation :cache_from_name
  validates_presence_of :from_name, unless: -> (m) { !m.info_request&.user }
  validates_inclusion_of :message_type, in: MESSAGE_TYPES
  validate :template_changed
  validate :body_uses_mixed_capitals
  validate :body_has_signature
  validate :what_doing_value

  belongs_to :info_request,
             inverse_of: :outgoing_messages
  belongs_to :incoming_message_followup,
             inverse_of: :outgoing_message_followups,
             foreign_key: 'incoming_message_followup_id',
             class_name: 'IncomingMessage',
             optional: true

  has_one :user,
          inverse_of: :outgoing_messages,
          through: :info_request

  # can have many events, for items which were resent by site admin e.g. if
  # contact address changed
  has_many :info_request_events,
           inverse_of: :outgoing_message,
           dependent: :destroy

  delegate :expire, :log_event, to: :info_request
  delegate :public_body, to: :info_request, private: true, allow_nil: true

  after_initialize :set_default_letter

  # Run after core association callbacks.
  after_create :request_limits_record
  after_save :touch_request_activity, if: :sent_activity_changed?

  # Exempts Deadlines::Reminder follow-ups from RequestLimits.
  attr_accessor :request_limits_exempt

  # prominence_reason is MessageProminence's.
  normalizes :body, :status, :message_type, :what_doing, :prominence,
             :from_name, with: Whitespace::TRIM

  admin_columns include: [:to, :from, :subject]

  default_url_options[:host] = AlaveteliConfiguration.domain

  scope :followup, -> { where(message_type: 'followup') }

  searchable PrivateArchive::Policy.searchable_options(
    index: {
      ".get_text_for_indexing": "A",
      ".safe_from_name": "D"
    },
    admin_index: {
      from_name: "B",
      prominence_reason: "D"
    },
    root: :info_request
  )

  def self.default_salutation(public_body)
    _("Dear {{public_body_name}},", public_body_name: public_body.name)
  end

  def self.fill_in_salutation(text, public_body)
    text.gsub(Template::BatchRequest.placeholder_salutation,
              default_salutation(public_body))
  end

  def self.with_body(body)
    # TODO: can add other databases here which have regexp_replace
    if ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
      # Exclude whitespace from the body comparison using regexp_replace
      where("regexp_replace(outgoing_messages.body, '[[:space:]]', '', 'g') =
             regexp_replace(?, '[[:space:]]', '', 'g')", body)
    else
      # For other databases (e.g. SQLite) not the end of the world being
      # space-sensitive for this check
      where(body: body)
    end
  end

  def default_message
    letter_template.body(default_message_replacements)
  end

  def add_signature(name)
    self.body = default_message + name if default_body?
  end

  def from_name
    super || info_request.user_name
  end

  def safe_from_name
    apply_all_masks(from_name, 'text/plain', redacted_attribute: :from_name)
  end

  # Public: The value to be used in the From: header of an OutgoingMailer
  # message.
  #
  # Returns a String
  def from
    info_request.incoming_name_and_email
  end

  # Public: The value to be used in the To: header of an OutgoingMailer message.
  #
  # Returns a String
  def to
    if replying_to_incoming_message?
      # calling safe_from_name from so censor rules are run
      MailHandler.address_from_name_and_email(
        incoming_message_followup.safe_from_name,
        incoming_message_followup.from_email
      )
    else
      info_request.recipient_name_and_email
    end
  end

  # Public: The value to be used in the Subject: header of an OutgoingMailer
  # message.
  #
  # Returns a String
  def subject
    if message_type == 'followup'
      if what_doing == 'internal_review'
        PlainTextTranslation._(
          "Internal review of {{email_subject}}",
          email_subject: info_request.email_subject_request(html: false)
        )
      else
        info_request.
          email_subject_followup(incoming_message: incoming_message_followup,
                                 html: false)
      end
    else
      info_request.email_subject_request(html: false)
    end
  end

  # Public: The body text of the OutgoingMessage. The text is cleaned and
  # CensorRules are applied.
  #
  # options - Hash of options
  #           :censor_rules - Array of CensorRules to apply. Defaults to the
  #                           black censor rules of the associated InfoRequest.
  #                           (optional)
  #
  # Returns a String
  def body(options = {})
    text = raw_body.dup
    return text if text.nil?

    text = clean_text(text)

    censor_rules = options.fetch(:censor_rules) do
      info_request ? info_request.masks_for(:requester).censor_rules : []
    end

    AlaveteliTextMasker.apply_masks(text, 'text/plain',
                                    censor_rules: Array(censor_rules),
                                    default_masks: false,
                                    redactable: self,
                                    redacted_attribute: :body)
  end

  def raw_body
    read_attribute(:body)
  end

  # Used to give warnings when writing new messages
  def contains_email?
    MySociety::Validate.email_find_regexp.match(body)
  end

  def contains_postcode?
    MySociety::Validate.contains_postcode?(body)
  end

  # An admin function
  def prepare_message_for_resend
    if MESSAGE_TYPES.include?(message_type) &&
       (status == 'sent' || status == 'failed')
      self.status = 'ready'
    else
      raise "Message id #{id} has type '#{message_type}' status " \
        "'#{status}' which prepare_message_for_resend can't handle"
    end
  end

  # We hide emails from display in outgoing messages.
  def remove_privacy_sensitive_things!(text)
    text.gsub!(MySociety::Validate.email_find_regexp, "[email address]")
  end

  # Returns text for indexing / text display
  def get_text_for_indexing(strip_salutation = true, opts = {})
    if opts.empty?
      text = body.strip
    else
      text = body(opts).strip
    end

    if strip_salutation && public_body
      salutation = self.class.default_salutation(public_body)
      text.sub!(/#{Regexp.escape(salutation)}\s*/, '')
    end

    # Remove email addresses from display/index etc.
    remove_privacy_sensitive_things!(text)

    text
  end

  # Return body for display as HTML
  def get_body_for_html_display # rubocop:disable Naming/AccessorMethodName -- the add-on calls it
    text = body.strip
    remove_privacy_sensitive_things!(text)
    text = CGI.escapeHTML(text)
    text = MySociety::Format.make_clickable(
      text, { contract: 1, nofollow: true }
    )
    text.gsub!(/\[(email address|mobile number)\]/,
               '[<a href="/help/officers#mobiles">\1</a>]')
    ActionController::Base.helpers.simple_format(
      text, {}, sanitize_options: { attributes: %w[href rel title] }
    )
  end

  # Return body for display as text
  def body_for_text_display
    get_text_for_indexing(false)
  end

  def default_letter=(text)
    original_default = default_message.clone
    @default_letter = text
    self.body = default_message if default_body?(original_default)
  end

  def update_and_log_event(event: {}, options: {}, **params)
    options[:skip_body_logging] ||= false

    old_tag_string = tag_string

    return false unless update(params)

    log_event(
      'edit_outgoing',
      event.merge(
        outgoing_message_id: id,
        old_body: options[:skip_body_logging] ? nil : body_previously_was,
        body: options[:skip_body_logging] ? nil : raw_body,
        body_changed: body_previously_changed?,
        old_prominence: prominence_previously_was,
        prominence: prominence,
        old_prominence_reason: prominence_reason_previously_was,
        prominence_reason: prominence_reason,
        old_tag_string: old_tag_string,
        tag_string: tag_string
      )
    )
  end

  private

  # Compares raw_body against the normalized template (body strips line breaks
  # and applies censor rules).
  def default_body?(template = default_message)
    raw_body == self.class.normalize_value_for(:body, template)
  end

  def cache_from_name
    return if read_attribute(:from_name)

    self.from_name = info_request.user_name if info_request
  end

  # Automatic classification: sending never marks unread replies as reviewed.
  def set_info_request_described_state
    automatic do
      if status == 'failed'
        record_failure_status
      elsif message_type == 'initial_request'
        info_request.set_described_state('waiting_response')
      elsif message_type == 'followup'
        record_followup_status
      end
      restore_status_after_resend
    end
  end

  def set_default_letter
    self.body = default_message if raw_body.nil?
  end

  def letter_template
    @letter_template ||=
      if what_doing == 'internal_review'
        Template::InternalReview.new
      elsif replying_to_incoming_message?
        Template::IncomingMessageFollowup.new
      else
        Template::InitialRequest.new
      end
  end

  def default_message_replacements
    opts = {}

    if info_request
      opts[:url] = request_url(info_request) if info_request.url_title
      opts[:info_request_title] = info_request.title if info_request.title
    end

    opts[:public_body_name] =
      if replying_to_incoming_message?
        OutgoingMailer.
          name_for_followup(info_request, incoming_message_followup)
      else
        public_body&.name
      end

    opts[:letter] = default_letter if default_letter

    opts
  end

  def replying_to_incoming_message?
    message_type == 'followup' &&
      incoming_message_followup &&
      incoming_message_followup.safe_from_name &&
      incoming_message_followup.followup_to_sender?
  end

  def template_changed
    # rubocop:disable Layout/LineLength -- a regex
    if raw_body.empty? || HTMLEntities.new.decode(raw_body) =~
                          /\A#{template_regex(letter_template.body(default_message_replacements))}/
      # rubocop:enable Layout/LineLength
      if message_type == 'followup'
        if what_doing == 'internal_review'
          errors.add(:body,
                     _("Please give details explaining why you want a review"))
        else
          errors.add(:body, _("Please enter your follow up message"))
        end
      elsif message_type == 'initial_request'
        errors.add(:body,
                   _("Please enter your letter requesting information"))
      end
    end
  end

  def template_regex(template_text)
    # in case we have '\r\n' or even '\r's all the way down
    text = template_text.tr("\r", "\n")
    # feels like this should need a gsub(/\//, '\/') but doesn't seem to
    Regexp.escape(text.squeeze("\n")).
      gsub("\\n", '\s*').
      gsub('\ \s*', '\s*').
      gsub('\s*\ ', '\s*')
  end

  def body_has_signature
    # rubocop:disable Layout/LineLength -- a regex
    if /#{template_regex(letter_template.signoff(default_message_replacements))}\s*\Z/m.match?(raw_body)
      # rubocop:enable Layout/LineLength
      errors.add(
        :body,
        _("Please sign at the bottom with your name, or alter the " \
          "\"{{signoff}}\" signature",
          signoff: letter_template.signoff(default_message_replacements))
      )
    end
  end

  def body_uses_mixed_capitals
    return if MySociety::Validate.uses_mixed_capitals(body)

    errors.add(:body,
               _('Please write your message using a mixture of capital ' \
                 'and lower case letters. This makes it easier for ' \
                 'others to read.'))
  end

  def what_doing_value
    return if WHAT_DOING_VALUES.include?(what_doing)

    errors.add(:what_doing_dummy,
               _('Please choose what sort of reply you are making.'))
  end

  # remove excess linebreaks that unnecessarily space it out
  def clean_text(text)
    text.strip.gsub(/(?:\n\s*){2,}/, "\n\n")
  end

  def request_limits_record
    return unless defined?(RequestLimits)
    return unless message_type == 'followup'
    return if request_limits_exempt

    RequestLimits.record!(info_request.user, :followup,
                          info_request_id: info_request_id)
  end

  def sent_activity_changed?
    status == 'sent' &&
      (saved_change_to_status? || saved_change_to_last_sent_at?)
  end

  def touch_request_activity
    info_request&.record_activity!(last_sent_at || Time.current)
  end
end
