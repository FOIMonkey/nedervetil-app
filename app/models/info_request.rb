# == Schema Information
#
# Table name: info_requests
#
#  id                                    :integer          not null, primary key
#  title                                 :text             not null
#  user_id                               :integer          not null
#  public_body_id                        :integer          not null
#  created_at                            :datetime         not null
#  updated_at                            :datetime         not null
#  described_state                       :string           not null
#  awaiting_description                  :boolean          default(FALSE), not null
#  prominence                            :string           default("requester_only"), not null
#  url_title                             :text             not null
#  law_used                              :string           default("foi"), not null
#  allow_new_responses_from              :string           default("anybody"), not null
#  handle_rejected_responses             :string           default("bounce"), not null
#  idhash                                :string           not null
#  attention_requested                   :boolean          default(FALSE)
#  info_request_batch_id                 :integer
#  last_public_response_at               :datetime
#  reject_incoming_at_mta                :boolean          default(FALSE), not null
#  rejected_incoming_count               :integer          default(0)
#  date_initial_request_last_sent_at     :date
#  date_response_required_by             :date
#  date_very_overdue_after               :date
#  last_event_forming_initial_request_id :integer
#  use_notifications                     :boolean
#  last_event_time                       :datetime
#  incoming_messages_count               :integer          default(0)
#  prominence_reason                     :text
#  last_activity_at                      :datetime
#

require 'digest/sha1'
require 'fileutils'

# A private FOI request from a User to a PublicBody, coordinating messages,
# events, deadlines, censor rules, gatekeeping, prominence and status.
class InfoRequest < ApplicationRecord
  OLD_AGE_IN_DAYS = 21.days
  REPORTED_STATES = %w[attention_requested requires_admin].freeze

  include Rails.application.routes.url_helpers
  include LinkToHelper

  include Categorisable
  include Searchable
  include Taggable
  include Notable
  include Redactable

  include AlaveteliPro::RequestSummaries
  include AlaveteliFeatures::Helpers

  include InfoRequest::BatchPagination
  include InfoRequest::Guessable
  include InfoRequest::HoldingPen
  include InfoRequest::MagicEmail
  include InfoRequest::Masking
  include InfoRequest::Sluggable
  include InfoRequest::TitleValidation

  # Why #revert_report! refuses; #report_reversion_blocker says which applies.
  RevertReportError = Class.new(StandardError)
  NotReportedError = Class.new(RevertReportError)
  UnreadRepliesError = Class.new(RevertReportError)
  NoClassificationBeforeReportError = Class.new(RevertReportError)
  SentSinceReportError = Class.new(RevertReportError)
  StaleReportError = Class.new(RevertReportError)

  admin_columns exclude: %i[title url_title],
                include: %i[rejected_incoming_count]

  def self.admin_title
    'Request'
  end

  normalizes :described_state, :prominence, :url_title, :law_used,
             :allow_new_responses_from, :handle_rejected_responses, :idhash,
             :prominence_reason, with: Whitespace::TRIM
  normalizes :title, with: Whitespace::ONE_LINE

  belongs_to :user,
             inverse_of: :info_requests,
             counter_cache: true,
             optional: true

  belongs_to :public_body,
             inverse_of: :info_requests,
             validate: false
  belongs_to :info_request_batch,
             inverse_of: :info_requests,
             optional: true

  validates_presence_of :public_body, message: N_("Please select an authority")

  has_many :info_request_events,
           -> { order(:created_at, :id) },
           inverse_of: :info_request,
           dependent: :destroy
  has_many :outgoing_messages,
           -> { order(:created_at) },
           inverse_of: :info_request,
           dependent: :destroy
  has_many :incoming_messages,
           -> { order(:created_at) },
           inverse_of: :info_request,
           dependent: :destroy
  has_many :user_info_request_sent_alerts,
           inverse_of: :info_request,
           dependent: :destroy
  has_many :censor_rules,
           -> { order(created_at: :desc) },
           as: :censorable,
           inverse_of: :censorable,
           dependent: :destroy
  has_many :mail_server_logs,
           -> { order(:mail_server_log_done_id, :order) },
           inverse_of: :info_request,
           dependent: :destroy
  has_many :foi_attachments, through: :incoming_messages

  attr_reader :followup_bad_reason

  scope :via_batch, -> { where.not(info_request_batch_id: nil) }

  # rubocop:disable Rails/ScopeArgs -- callable query objects implementing #call
  scope :visible_to_requester, Prominence::VisibleToRequesterQuery.new

  scope :awaiting_response, State::AwaitingResponseQuery.new
  scope :response_received, State::ResponseReceivedQuery.new
  scope :clarification_needed, State::ClarificationNeededQuery.new
  scope :complete, State::CompleteQuery.new
  scope :other, State::OtherQuery.new
  scope :overdue, State::OverdueQuery.new
  scope :very_overdue, State::VeryOverdueQuery.new

  class << self
    alias in_progress awaiting_response
  end
  scope :action_needed, State::ActionNeededQuery.new
  # rubocop:enable Rails/ScopeArgs
  scope :updated_before,
        ->(ts) { where('"info_requests"."updated_at" < ?', ts) }

  # user described state (also update in info_request_event,
  # admin/requests/edit)
  validate :must_be_valid_state
  validates_inclusion_of :prominence, in: Prominence::VALUES

  validates_inclusion_of :law_used, in: Legislation.keys

  before_create { self.last_activity_at ||= Time.current }

  # who can send new responses
  validates_inclusion_of :allow_new_responses_from, in: [
    'anybody', # anyone who knows the request email address
    'authority_only', # only people from authority domains
    'nobody'
  ]
  # what to do with refused new responses
  validates_inclusion_of :handle_rejected_responses, in: [
    'bounce', # return them to sender
    'holding_pen', # put them in the holding pen
    'blackhole' # just dump them
  ]

  after_initialize :set_defaults
  before_create :set_use_notifications
  before_validation :set_law_used, on: :create
  before_destroy :expire

  # Callback order matters: run after core validation/expire callbacks, and
  # save deadline associations before request_limits_record runs.
  after_update :invalidate_attention_predictions
  before_destroy :destroy_documents
  has_many :deadline_adjustments, class_name: 'Deadlines::Adjustment',
                                  inverse_of: :info_request,
                                  dependent: :delete_all
  has_many :deadline_closures, class_name: 'Deadlines::Closure',
                               inverse_of: :info_request,
                               dependent: :delete_all
  after_create :request_limits_record

  # Preloaded by Deadlines::Stage to avoid per-row queries on list views.
  attr_accessor :thread_shared
  attr_accessor :deadlines_auto_classified_ids, :deadlines_batch

  searchable PrivateArchive::Policy.searchable_options(
    index: {
      title: "A",
      url_title: "B"
    },
    admin_index: {
      prominence_reason: "D"
    }
  )

  def self.custom_states_loaded
    @@custom_states_loaded
  end

  # When constructing a new request, use this to check user hasn't double
  # submitted.
  # TODO: could have a date range here, so say only check last month's worth
  # of new requests. If somebody is making repeated requests, say once a
  # quarter for time information, then might need to do that.
  # TODO: this *should* also check outgoing message joined to is an initial
  # request (rather than follow up)
  # `within:` is required so callers never search across other users' private
  # requests by default.
  def self.find_existing(title, public_body_id, body, within:)
    conditions = { title: title&.squish, public_body_id: public_body_id }

    within.
      includes(:outgoing_messages).
        where(conditions).
          merge(OutgoingMessage.with_body(body)).
            references(:outgoing_messages).
              first
  end

  # states which require administrator action (hence email administrators
  # when they are entered, and offer state change dialog to them)
  def self.requires_admin_states
    %w(requires_admin error_message attention_requested)
  end

  # Display version of status
  def self.get_status_description(status)
    descriptions = {
      'waiting_classification' => _('Waiting classification'),
      'waiting_response' => _('Waiting response'),
      'waiting_response_overdue' => _('Waiting response, overdue'),
      'waiting_response_very_overdue' => _('Waiting response, long overdue'),
      'not_held' => _('No information'),
      'rejected' => _('No information'),
      'partially_successful' => _('Some information provided'),
      'successful' => _('All information provided'),
      'waiting_clarification' => _("Waiting clarification"),
      'gone_postal' => _("Handled by postal mail"),
      'internal_review' => _('Internal review'),
      'under_appeal' => _('Under appeal'),
      'error_message' => _("Delivery error"),
      'requires_admin' => _("Unusual response"),
      'attention_requested' => _("Reported for administrator attention"),
      'user_withdrawn' => _("Withdrawn by the requester"),
      'vexatious' => _("Considered by administrators as vexatious"),
      'not_foi' => _("Considered by administrators as not an FOI request")
    }
    if descriptions[status]
      descriptions[status]
    elsif respond_to?(:theme_display_status)
      theme_display_status(status)
    else
      raise _("unknown status {{status}}", status: status)
    end
  end

  def self.build_from_attributes(info_request_atts, outgoing_message_atts, user = nil)
    info_request = new(info_request_atts)
    default_message_params = {
      status: 'ready',
      message_type: 'initial_request',
      what_doing: 'normal_sort'
    }

    attrs = outgoing_message_atts.merge(default_message_params)

    outgoing_message = OutgoingMessage.new(attrs)
    info_request.outgoing_messages << outgoing_message
    outgoing_message.info_request = info_request
    info_request.user = user
    info_request
  end

  def self.from_draft(draft)
    info_request = new(title: draft.title,
                       user: draft.user,
                       public_body: draft.public_body)
    info_request.outgoing_messages.new(body: draft.body,
                                       status: 'ready',
                                       message_type: 'initial_request',
                                       what_doing: 'normal_sort',
                                       info_request: info_request)
    info_request
  end

  def self.where_old_unclassified(age_in_days = nil)
    age_in_days =
      if age_in_days
        age_in_days.days
      else
        OLD_AGE_IN_DAYS
      end

    where("awaiting_description = ?
          AND last_public_response_at < ?
          AND url_title != 'holding_pen'
          AND user_id IS NOT NULL",
          true, Time.zone.now - age_in_days)
  end

  def self.reject_incoming_at_mta(options)
    query = InfoRequest.where(
      updated_at: ...options[:age_in_months].months.ago,
      rejected_incoming_count: options[:rejection_threshold]..,
      allow_new_responses_from: 'nobody',
      reject_incoming_at_mta: false
    ).where.not(url_title: 'holding_pen')

    yield query.pluck(:id) if block_given?

    if options[:dryrun]
      0
    else
      query.update_all(reject_incoming_at_mta: true)
    end
  end

  def self.requests_old_after_months
    AlaveteliConfiguration.restrict_new_responses_on_old_requests_after_months
  end

  def self.requests_very_old_after_months
    requests_old_after_months * 4
  end

  # This is called from cron regularly.
  def self.stop_new_responses_on_old_requests
    # 'old' months since last change to request, only allow new incoming
    # messages from authority domains
    InfoRequest.
      where(allow_new_responses_from: 'anybody').
      where.not(url_title: 'holding_pen').
      updated_before(requests_old_after_months.months.ago.to_date).
      distinct.
      find_in_batches do |batch|
        batch.each do |info_request|
          old_allow_new_responses_from = info_request.allow_new_responses_from

          info_request.
            update_column(:allow_new_responses_from, 'authority_only')

          params =
            { old_allow_new_responses_from: old_allow_new_responses_from,
              allow_new_responses_from: info_request.allow_new_responses_from,
              editor: 'InfoRequest.stop_new_responses_on_old_requests' }

          info_request.log_event('edit', params)
        end
      end

    # 'very_old' months since last change to request, don't allow any new
    # incoming messages
    InfoRequest.
      where(allow_new_responses_from: %w[anybody authority_only]).
      where.not(url_title: 'holding_pen').
      updated_before(requests_very_old_after_months.months.ago.to_date).
      distinct.
      find_in_batches do |batch|
        batch.each do |info_request|
          old_allow_new_responses_from = info_request.allow_new_responses_from

          info_request.
            update_column(:allow_new_responses_from, 'nobody')

          params =
            { old_allow_new_responses_from: old_allow_new_responses_from,
              allow_new_responses_from: info_request.allow_new_responses_from,
              editor: 'InfoRequest.stop_new_responses_on_old_requests' }

          info_request.log_event('edit', params)
        end
      end
  end

  def self.log_overdue_events
    log_overdue_event_type('overdue')
  end

  def self.log_very_overdue_events
    log_overdue_event_type('very_overdue')
  end

  def self.log_overdue_event_type(event_type)
    date_field = case event_type
                 when 'overdue'
                   'date_response_required_by'
                 when 'very_overdue'
                   'date_very_overdue_after'
                 else
                   raise ArgumentError, "Event type #{event_type} not handled"
                 end

    query =
      where(["awaiting_description = ?
              AND described_state = ?
              AND #{date_field} < ?
              AND NOT EXISTS (SELECT 1
              FROM info_request_events
              WHERE info_request_id = info_requests.id
              AND event_type = ?
              AND created_at > info_requests.#{date_field})",
             false,
             'waiting_response',
             Time.zone.today,
             event_type])

    query.find_each(batch_size: 100) do |info_request|
      # Date to DateTime representing beginning of day
      created_at = info_request.send(date_field).beginning_of_day + 1.day
      event = info_request.log_event(
        event_type,
        { event_created_at: Time.zone.now },
        created_at: created_at
      )
      info_request.user.notify(event) if info_request.use_notifications?
    end
  end

  def self.request_sent_types
    %w(sent resent followup_sent followup_resent send_error)
  end

  # Possible reasons that a request could be reported for administrator
  # attention
  def report_reasons
    [_("Contains defamatory material"),
     _("Not a valid request"),
     _("Request for personal information"),
     _("Contains personal information"),
     _("Vexatious"),
     _("Other")]
  end

  # Public: Overrides the ActiveRecord attribute accessor
  #
  # opts = Hash of options (default: {})
  #        :decorate - Wrap the string in a ProminenceCalculator decorator that
  #        has methods indicating whether the InfoRequest is public, searchable
  #        etc.
  # Returns a String or ProminenceCalculator
  def prominence(opts = {})
    decorate = opts.fetch(:decorate, false)
    if decorate
      Prominence::Calculator.new(self)
    else
      read_attribute(:prominence)
    end
  end

  # opts = Hash of options (default: {})
  # Returns a StateCalculator
  def state(_opts = {})
    State::Calculator.new(self)
  end

  def internal_review_requested?
    outgoing_messages.where(what_doing: 'internal_review').any?
  end

  def user_name
    user&.name
  end

  def from_name
    outgoing_messages.first&.from_name || user_name
  end

  def safe_from_name
    apply_all_masks(from_name, 'text/plain',
                    redactable: self, redacted_attribute: :from_name)
  end

  # Classifiable keeps the controllers' copy of this flag the same way.
  # rubocop:disable Style/ClassVars -- set once at load; specs switch it on
  @@custom_states_loaded = false
  begin
    require 'customstates'
    include InfoRequestCustomStates
    @@custom_states_loaded = true
  rescue LoadError, NameError
    # No theme provides custom states; use the base ones.
  end
  # rubocop:enable Style/ClassVars

  def expire(options = {})
    clear_attachment_masks! unless options[:preserve_attachment_masks]

    foi_fragment_cache_directories.each { |dir| FileUtils.rm_rf(dir) }
    RegulatorPack.purge_for_request!(id)

    clear_in_database_caches! unless options[:preserve_database_cache]
  end

  def clear_attachment_masks!
    foi_attachments.update_all(masked_at: nil)
  end

  def record_activity!(at = Time.current)
    return if last_activity_at && last_activity_at >= at

    update_column(:last_activity_at, at)
  end

  # Single UPDATE avoids re-saving the request once per message.
  def clear_in_database_caches!
    incoming_messages.where('cached_main_body_text_unfolded IS NOT NULL ' \
                            'OR cached_main_body_text_folded IS NOT NULL').
      update_all(cached_main_body_text_unfolded: nil,
                 cached_main_body_text_folded: nil,
                 updated_at: Time.current)
    incoming_messages.reset
  end

  def update_last_public_response_at
    last_public_event = last_public_response_event
    if last_public_event
      self.last_public_response_at = last_public_event.created_at
    else
      self.last_public_response_at = nil
    end
    save!
  end

  # Remove spaces from ends (for when used in emails etc.)
  # Needed for titles stored before they were normalised
  def title
    title = read_attribute(:title)
    title.strip! if title
    title
  end

  def incoming_name_and_email
    MailHandler.address_from_name_and_email(user_name, incoming_email)
  end

  # Subject lines for emails about the request
  def email_subject_request(opts = {})
    values = { law_used_full: legislation.to_s(:full), title: title }
    if opts.fetch(:html, true)
      _('{{law_used_full}} request - {{title}}', values)
    else
      PlainTextTranslation._('{{law_used_full}} request - {{title}}', values)
    end
  end

  def email_subject_followup(opts = {})
    incoming_message = opts.fetch(:incoming_message, nil)
    html = opts.fetch(:html, true)
    if incoming_message.nil? || !incoming_message.followup_to_sender? ||
       !incoming_message.subject
      # Text to text, and HTML to HTML: a page escapes a plain String again.
      subject = email_subject_request(html: html)
      html ? ERB::Util.html_escape('Re: ') + subject : "Re: #{subject}"
    elsif /^Re:/i.match?(incoming_message.subject)
      incoming_message.subject
    else
      'Re: ' + incoming_message.subject
    end
  end

  def legislation
    return Legislation.find!(law_used) if law_used

    public_body&.legislation || Legislation.default
  end

  def find_existing_outgoing_message(body)
    outgoing_messages.with_body(body).first
  end

  # Deduplicates by inbound message_id (or checksum-derived ID when absent)
  # so re-routed mail is not recorded twice.
  def already_received?(mail, message_id = nil)
    message_id ||= mail.message_id
    return false unless message_id

    incoming_messages.any? { message_id == _1.message_id }
  end

  def receive(mail, override_stop_new_responses: false, rejected_reason: nil,
              message_id: nil, message_checksum: nil)
    return if already_received?(mail, message_id)

    accepted = override_stop_new_responses || accept_incoming?(
      mail, message_id: message_id, message_checksum: message_checksum
    )
    return unless accepted

    incoming_message = create_response!(
      mail, rejected_reason: rejected_reason, message_id: message_id,
            message_checksum: message_checksum
    )

    # Notify the user that a new response has been received
    if use_notifications?
      info_request_event = info_request_events.find_by(
        event_type: 'response',
        incoming_message_id: incoming_message.id
      )
      user.notify(info_request_event)
    else
      RequestMailer.new_response(self, incoming_message).deliver_now
    end

    incoming_message
  end

  def receive_redelivery(incoming_message, editor:)
    receive(incoming_message.raw_email.mail, override_stop_new_responses: true)

    incoming_message.info_request.log_event(
      'redeliver_incoming',
      editor: editor,
      destination_request: id,
      deleted_incoming_message_id: incoming_message.id,
      storage_keys: incoming_message.storage_keys
    )
  end

  # Called when outgoing_messages are sent to ensure that the request
  # is not closed during an active discussion or an internal review
  def reopen_to_new_responses
    update(allow_new_responses_from: 'anybody', reject_incoming_at_mta: false)
  end

  def requires_admin?
    self.class.requires_admin_states.include?(described_state)
  end

  def reported?
    REPORTED_STATES.include?(described_state)
  end

  # Report this request for administrator attention
  def report!(reason, message, user)
    ActiveRecord::Base.transaction do
      log_event(
        'report_request',
        request_id: id,
        editor: user,
        reason: reason,
        message: message,
        old_attention_requested: attention_requested,
        attention_requested: true
      )

      set_described_state('attention_requested', user,
                          "Reason: #{reason}\n\n#{message}")
      # tells us if attention has ever been requested
      self.attention_requested = true
      save!
    end
  end

  delegate :last_report_event,
           :last_classification_event_before_report,
           :classification_before_report,
           :replies_classified_by_report,
           to: :report_reversion

  def report_reversion
    InfoRequest::ReportReversion.new(self)
  end

  def revert_report!(editor:, report_event_id: nil)
    report_reversion.revert!(editor: editor, report_event_id: report_event_id)
  end

  def report_reversion_blocker
    report_reversion.blocker
  end

  # change status, including for last event for later historical purposes
  # described_state should always indicate the current state of the request, as
  # described by the request owner (or, in some other cases an admin or other
  # user)
  def set_described_state(new_state, set_by = nil, message = "")
    if IncomingAttention::Classification.automatic?
      return change_described_state(new_state, set_by, message)
    end

    self.class.transaction do
      IncomingAttention::Outcome.overridden!(self, new_state)
      # Lock a fresh copy without discarding the caller's unsaved attributes.
      self.class.lock.find(id)
      change_described_state(new_state, set_by, message).tap do
        # Human classification covers replies received so far, not later ones.
        IncomingAttention::Prediction.
          where(incoming_message_id: incoming_messages.select(:id)).
          update_all(human_reviewed_at: Time.current)
      end
    end
  end

  # Normalizes not_held to rejected so lists, filters and search use one state.
  private def change_described_state(new_state, set_by, message)
    new_state = 'rejected' if new_state == 'not_held'
    old_described_state = described_state
    ActiveRecord::Base.transaction do
      self.awaiting_description = false
      last_event = info_request_events.last
      last_event.described_state = new_state

      self.described_state = new_state
      last_event.save!
      save!
    end

    calculate_event_states

    return unless old_described_state != described_state && requires_admin?

    # Check there is someone to send the message "from"
    return unless set_by && user

    RequestMailer.requires_admin(self, set_by, message).deliver_now
  end

  # Work out what state to display for the request on the site. In addition to
  # values of self.described_state, can take these values:
  #   waiting_classification
  #   waiting_response_overdue
  #   waiting_response_very_overdue
  # (this method adds an assessment of overdueness with respect to the current
  # time to 'waiting_response' states, and will return 'waiting_classification'
  # instead of the described_state if the awaiting_description flag is set on
  # the request).
  def calculate_status(cached_value_ok = false)
    if cached_value_ok && @cached_calculated_status
      return @cached_calculated_status
    end

    @cached_calculated_status = if @@custom_states_loaded
                                  theme_calculate_status
                                else
                                  base_calculate_status
                                end
  end

  def base_calculate_status
    return 'waiting_classification' if awaiting_description
    return described_state unless described_state == "waiting_response"
    # Compare by date, so only overdue on next day, not if 1 second late
    if Time.zone.now.strftime("%Y-%m-%d") >
       date_very_overdue_after.strftime("%Y-%m-%d")
      return 'waiting_response_very_overdue'
    end
    if Time.zone.now.strftime("%Y-%m-%d") >
       date_response_required_by.strftime("%Y-%m-%d")
      return 'waiting_response_overdue'
    end

    'waiting_response'
  end

  # 'described_state' can be populated on any info_request_event but is only
  # ever used in the process populating calculated_state on the
  # info_request_event (if it represents a response, outgoing message, edit
  # or status update), or previous response or outgoing message events for
  # the same request.

  # Fill in any missing event states for first response before a description
  # was made. i.e. We take the last described state in between two responses
  # (inclusive of earlier), and set it as calculated value for the earlier
  # response. Also set the calculated state for any initial outgoing message,
  # follow up, edit or status_update to the described state of that event.
  #
  # A report (REPORTED_STATES) only labels a response when no other state
  # intervened, so reporting never erases a prior classification.

  # The calculated state of the latest info_request_event is the request's
  # status, so it should match the described_state of the info_request.
  def calculate_event_states
    curr_state = nil
    info_request_events.reverse_each do |event|
      if curr_state.nil? || (REPORTED_STATES.include?(curr_state) &&
                             event.described_state &&
                             !REPORTED_STATES.include?(event.described_state))
        curr_state = event.described_state if event.described_state
      end

      if curr_state && event.event_type == 'response'
        event.set_calculated_state!(curr_state)

        if event.last_described_at.nil? # TODO: actually maybe this isn't needed
          event.last_described_at = Time.zone.now
          event.save!
        end
        curr_state = nil
      elsif curr_state &&
            (event.event_type == 'followup_sent' ||
             event.event_type == 'sent') &&
            event.described_state &&
            (event.described_state == 'waiting_response' ||
             event.described_state == 'internal_review')
        # Followups can set the status to waiting response / internal
        # review. Initial requests ('sent') set the status to waiting response.

        # We want to store that in calculated_state.
        event.set_calculated_state!(event.described_state)

        # And we don't want to propagate it to the response itself,
        # as that might already be set to waiting_clarification / a
        # success status, which we want to know about.
        curr_state = nil
      elsif curr_state && (%w[edit status_update].include? event.event_type)
        # A status update or edit event should get the same calculated state
        # as described state, so that the described state is the latest
        # calculated state immediately after the request has been described,
        # regardless of what other request events precede it. These events
        # allow the described state to propagate in case there is a preceding
        # response that the described state should be applied to.
        event.set_calculated_state!(event.described_state)
      end
    end
  end

  # Find last InfoRequestEvent which  was:
  # -- sent at all
  # -- OR the same message was resent
  # -- OR the public body requested clarification, and a follow up was sent
  def last_event_forming_initial_request
    info_request_event_id =
      read_attribute(:last_event_forming_initial_request_id)
    last_sent = if info_request_event_id
                  InfoRequestEvent.find_by_id(info_request_event_id)
                else
                  calculate_last_event_forming_initial_request
                end

    if last_sent.nil?
      raise "internal error, last_event_forming_initial_request gets nil for " \
            "request #{ id } outgoing messages count " \
            "#{ outgoing_messages.size } all events: " \
            "#{ info_request_events.to_yaml }"
    end

    last_sent
  end

  def calculate_last_event_forming_initial_request
    # TODO: This can be removed when last_event_forming_initial_request_id has
    # been populated for all requests

    expecting_clarification = false
    last_sent = nil
    info_request_events.each do |event|
      if event.described_state == 'waiting_clarification'
        expecting_clarification = true
      end

      if self.class.request_sent_types.include?(event.event_type)
        if last_sent.nil? ||
           event.event_type == 'resent' ||
           (event.event_type == 'send_error' &&
            event.outgoing_message.message_type == 'initial_request')
          last_sent = event
        elsif expecting_clarification && event.event_type == 'followup_sent'
          # TODO: this needs to cope with followup_resent, which it doesn't.
          # Not really easy to do, and only affects cases where followups
          # were resent after a clarification.
          last_sent = event
          expecting_clarification = false
        end
      end
    end
    last_sent
  end

  # Log an event to the history of some things that have happened to this
  # request
  def log_event(type, params, options = {})
    event = info_request_events.create!(event_type: type, params: params)
    update_due_dates(event) if event.resets_due_dates?
    if options[:created_at]
      event.update_column(:created_at, options[:created_at])
    end
    if !last_event_time || (event.created_at > last_event_time)
      update_column(:last_event_time, event.created_at)
    end
    event
  end

  def update_due_dates(sent_event)
    self.last_event_forming_initial_request_id = sent_event.id
    self.date_initial_request_last_sent_at = sent_event.created_at.to_date
    self.date_response_required_by = calculate_date_response_required_by
    self.date_very_overdue_after = calculate_date_very_overdue_after
    save!
  end

  # TODO: once date_initial_request_sent_at is populated for all
  # requests, this can be removed
  # The last time that the initial request was sent/resent
  def date_initial_request_last_sent_at
    date = read_attribute(:date_initial_request_last_sent_at)
    return date.to_date if date

    calculate_date_initial_request_last_sent_at
  end

  # TODO: once date_initial_request_sent_at is populated for all
  # requests, this can be removed
  def calculate_date_initial_request_last_sent_at
    last_sent = last_event_forming_initial_request
    last_sent.outgoing_message.last_sent_at.to_date
  end

  def late_calculator
    @late_calculator ||= DefaultLateCalculator.new
  end

  # TODO: once date_response_required_by is populated for all
  # requests, this can be removed
  def date_response_required_by
    date = read_attribute(:date_response_required_by)
    return date if date

    calculate_date_response_required_by
  end

  def calculate_date_response_required_by
    Deadlines::Calendar.due_date_for(
      self,
      from: date_initial_request_last_sent_at,
      days: late_calculator.reply_late_after_days
    )
  end

  # TODO: once date_very_overdue_after is populated for all
  # requests, this can be removed
  def date_very_overdue_after
    date = read_attribute(:date_very_overdue_after)
    return date if date

    calculate_date_very_overdue_after
  end

  def calculate_date_very_overdue_after
    Deadlines::Calendar.due_date_for(
      self,
      from: date_initial_request_last_sent_at,
      days: late_calculator.reply_very_late_after_days
    )
  end

  # Where the initial request is sent to
  def recipient_email
    public_body.request_email
  end

  def recipient_email_valid_for_followup?
    public_body.is_followupable?
  end

  def recipient_name_and_email
    # TRANSLATORS: Please don't use double quotes (") in this translation
    # or it will break the site's ability to send emails to authorities!
    recipient_name = _("{{law_used_short}} requests at {{public_body}}",
                       law_used_short: legislation,
                       public_body: public_body.short_or_long_name)

    if MySociety::Validate.is_valid_email(recipient_email)
      MailHandler.address_from_name_and_email(recipient_name, recipient_email)
    else
      recipient_name
    end
  end

  # Responses visible to the requester (upstream method name kept for themes).
  def public_response_events
    info_request_events.
      joins(:incoming_message).
      where(event_type: 'response').
      where(Ability::RequesterVisible.sql(message: 'incoming_messages'))
  end

  # The last public response is the default one people might want to reply to
  def last_public_response_event
    public_response_events.last
  end

  def last_public_response
    last_public_response_event&.incoming_message
  end

  def last_event_id_needing_description
    last_event = events_needing_description[-1]
    last_event.nil? ? 0 : last_event.id
  end

  # Returns all the events which the user hasn't described yet - an empty array
  # if all described.
  def events_needing_description
    events = info_request_events
    i = index_of_last_described_event
    if i.nil?
      events
    else
      events[i + 1, events.size]
    end
  end

  # Public: The most recent InfoRequestEvent.
  #
  # Returns an InfoRequestEvent or nil
  def last_event
    info_request_events.last
  end

  # Get previous email sent to
  def get_previous_email_sent_to(info_request_event)
    last_email = nil
    info_request_events.each do |e|
      if ((info_request_event.is_sent_sort? && e.is_sent_sort?) ||
          (info_request_event.is_followup_sort? && e.is_followup_sort?)) &&
         e.outgoing_message_id == info_request_event.outgoing_message_id
        break if e.id == info_request_event.id

        last_email = e.params[:email]
      end
    end
    last_email
  end

  def display_status(cached_value_ok = false)
    InfoRequest.get_status_description(calculate_status(cached_value_ok))
  end

  def foi_fragment_cache_directories
    # return stub path so admin can expire it
    directories = []
    path = File.join("request", request_dirs)
    foi_cache_path = File.expand_path(File.join(Rails.root, 'cache', 'views'))
    directories << File.join(foi_cache_path, path)
    AlaveteliLocalization.available_locales.each do |locale|
      directories << File.join(foi_cache_path, locale, path)
    end

    directories
  end

  def is_followupable?(incoming_message)
    if OutgoingMailer.is_followupable?(self, incoming_message)
      @followup_bad_reason = nil
      true
    else
      @followup_bad_reason = if public_body.is_requestable?
                               "unexpected followupable inconsistency"
                             else
                               public_body.not_requestable_reason
                             end
      false
    end
  end

  def postal_email
    if who_can_followup_to.empty?
      public_body.request_email
    else
      who_can_followup_to[-1][1]
    end
  end

  def postal_email_name
    if who_can_followup_to.empty?
      public_body.name
    else
      who_can_followup_to[-1][0]
    end
  end

  def request_dirs
    first_three_digits = id.to_s[0..2]
    File.join(first_three_digits.to_s, id.to_s)
  end

  def reason_to_be_unhappy?
    classified? && State.unhappy.include?(calculate_status)
  end

  def classified?
    !awaiting_description?
  end

  def is_old_unclassified?
    awaiting_description && url_title != 'holding_pen' &&
      last_public_response_event &&
      Time.zone.now >
        last_public_response_event.created_at + OLD_AGE_IN_DAYS
  end

  # List of incoming messages to followup, by unique email
  def who_can_followup_to(skip_message = nil)
    ret = []
    done = {}
    if skip_message
      if (email = OutgoingMailer.email_for_followup(self, skip_message))
        done[email.downcase] = 1
      end
    end
    incoming_messages.reverse_each do |incoming_message|
      next if incoming_message == skip_message

      incoming_message.safe_from_name

      next unless Ability::RequesterVisible.own(incoming_message) == :requester

      email = OutgoingMailer.email_for_followup(self, incoming_message)
      name = OutgoingMailer.name_for_followup(self, incoming_message)

      unless done.include?(email.downcase)
        ret += [[name, email, incoming_message.id]]
      end
      done[email.downcase] = 1
    end

    unless done.include?(public_body.request_email.downcase)
      ret += [[public_body.name, public_body.request_email, nil]]
    end
    done[public_body.request_email.downcase] = 1

    ret.reverse
  end

  def is_actual_owning_user?(user)
    return false unless user

    user.id == user_id
  end

  def move_to_public_body(destination_public_body, opts = {})
    return nil unless destination_public_body.try(:persisted?)

    old_body = public_body
    editor = opts.fetch(:editor)

    attrs = { public_body: destination_public_body }

    if destination_public_body
      attrs[:law_used] = destination_public_body.legislation.key
    end

    return_val = if update(attrs)
                   log_event(
                     'move_request',
                     editor: editor,
                     public_body_url_name: public_body.url_name,
                     old_public_body_url_name: old_body.url_name
                   )

                   public_body
                 end

    return_val
  end

  def move_to_user(destination_user, opts = {})
    return nil unless destination_user.try(:persisted?)

    old_user = user
    editor = opts.fetch(:editor)

    return_val = if update(user: destination_user)
                   log_event(
                     'move_request',
                     editor: editor,
                     user_url_name: user.url_name,
                     old_user_url_name: old_user.url_name
                   )

                   user
                 end

    # HACK: Manually reset counter caches
    # https://github.com/rails/rails/issues/10865
    old_user.class.reset_counters(old_user.id, :info_requests)
    user.class.reset_counters(user.id, :info_requests)
    return_val
  end

  # @see RequestSummaries#should_summarise?
  def should_summarise?
    info_request_batch_id.blank?
  end

  # Requests in a batch should update their parent batch request when they
  # are updated.
  #
  # @see RequestSummaries#should_update_parent_summary?
  def should_update_parent_summary?
    info_request_batch_id.present?
  end

  # @see RequestSummaries#request_summary_parent
  def request_summary_parent
    if info_request_batch_id.blank?
      nil
    else
      info_request_batch
    end
  end

  # @see RequestSummaries#request_summary_body
  def request_summary_body
    outgoing_messages.any? ? outgoing_messages.first.body : ""
  end

  # @see RequestSummaries#request_summary_public_body_names
  def request_summary_public_body_names
    public_body.name unless public_body.blank?
  end

  # @see RequestSummaries#request_summary_categories
  def request_summary_categories
    categories = []
    # A request with no events is in the process of being sent (probably
    # having been created within our tests rather than in real code) and will
    # error if we try to get the phase, skip it for now because it'll be saved
    # when it's sent and trigger this code again anyway.
    if last_event_forming_initial_request_id.present?
      phase_slug = state.phase.to_s
      phase = AlaveteliPro::RequestSummaryCategory.find_by(slug: phase_slug)
      categories << phase unless phase.blank?
    end
    categories
  end

  def latest_refusals
    incoming_messages.reverse_each.find(&:refusals?)&.refusals || []
  end

  # Return only this request in a chainable relation. This is mainly for
  # duck-typing with other censorable relationships.
  def info_requests
    self.class.where(id: id)
  end

  # Expire this request. This is mainly for
  # duck-typing with other censorable relationships.
  def expire_requests
    InfoRequest::ExpireJob.perform_later(self)
  end

  private

  def self.add_conditions_from_extra_params(params, extra_params)
    return unless extra_params[:conditions]

    condition_string = extra_params[:conditions].shift
    params[:conditions][0] += " AND #{condition_string}"
    params[:conditions] += extra_params[:conditions]
  end
  private_class_method :add_conditions_from_extra_params

  def accept_incoming?(mail, **inbound_ids)
    # See if new responses are prevented
    gatekeeper = ResponseGatekeeper.for(allow_new_responses_from, self)
    # Take action if the message looks like spam
    spam_checker = ResponseGatekeeper::SpamChecker.new

    # What rejected the email – the gatekeeper or the spam checker?
    response_rejector =
      if gatekeeper.allow?(mail)
        if spam_checker.allow?(mail)
          nil
        else
          spam_checker
        end
      else
        gatekeeper
      end

    # Figure out how to reject the mail if it was rejected
    response_rejection =
      if response_rejector
        ResponseRejection.for(response_rejector.rejection_action, self, mail,
                              **inbound_ids)
      end

    will_be_rejected = (response_rejector && response_rejection) ? true : false
    if will_be_rejected && response_rejection.reject(response_rejector.reason)
      # update without changing the updated_at field
      update_column(:rejected_incoming_count, rejected_incoming_count.next)
      logger.info "Rejected incoming mail: #{ response_rejector.reason } " \
                  "request: #{ id }"
      false
    else
      true
    end
  end

  def create_response!(mail, rejected_reason: nil, message_id: nil,
                       message_checksum: nil)
    incoming_message = incoming_messages.build

    # To avoid a deadlock when simultaneously dealing with two
    # incoming emails that refer to the same InfoRequest, we
    # lock the row for update.
    with_lock do
      # TODO: These are very tightly coupled
      raw_email = incoming_message.build_raw_email(
        message_id: message_id,
        message_checksum: message_checksum
      )
      incoming_message.save!

      raw_email.update(mail: mail)
      incoming_message.store_header_values_on_receipt

      unless described_state == 'user_withdrawn'
        self.awaiting_description = true
      end

      params = { incoming_message_id: incoming_message.id }
      params[:rejected_reason] = rejected_reason.to_s if rejected_reason
      log_event('response', params)

      save!
    end

    incoming_message
  end

  # Returns index of last event which is described or nil if none described.
  def index_of_last_described_event
    info_request_events.reverse.each_with_index do |event, index|
      if event.described_state
        reverse_index = info_request_events.size - 1 - index
        return reverse_index
      end
    end
    nil
  end

  def set_defaults
    self.described_state = 'waiting_response' if described_state.nil?
  rescue ActiveModel::MissingAttributeError
    # this should only happen on Model.exists? call. It can be safely ignored.
    # See http://www.tatvartha.com/2011/03/activerecordmissingattributeerror-missing-attribute-a-bug-or-a-features/
  end

  def set_law_used
    return if law_used_changed?

    self.law_used = public_body.legislation.key if public_body
  end

  # All non-holding-pen user requests use notifications (set once on create).
  def set_use_notifications
    return unless use_notifications.nil?

    self.use_notifications =
      holding_pen_request?(read_only: true) ? false : user.present?
  end

  def must_be_valid_state
    return if State.all.include?(described_state)

    errors.add(:described_state, "is not a valid state")
  end

  def destroy_documents
    Disclosures::Document.where(info_request_id: id).find_each do |document|
      document.purge_public_pages!
      document.destroy!
    end
  end

  def request_limits_record
    return if info_request_batch_id

    RequestLimits.record!(user, :request, info_request_id: id)
  end

  def invalidate_attention_predictions
    return unless saved_change_to_user_id? || saved_change_to_prominence?

    IncomingAttention::Prediction.where(info_request_id: id).
      pluck(:incoming_message_id).each do |message_id|
        IncomingAttention::Prediction.invalidate_message(
          message_id, 'visibility_changed'
        )
      end
  end
end
