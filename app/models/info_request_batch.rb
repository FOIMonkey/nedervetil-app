# == Schema Information
#
# Table name: info_request_batches
#
#  id         :integer          not null, primary key
#  title      :text             not null
#  user_id    :integer          not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  body       :text
#  sent_at    :datetime
#

# Queues and sends one InfoRequest per requestable authority in a batch,
# enforcing batch limits and summarising child request phases for the inbox.
class InfoRequestBatch < ApplicationRecord
  include AlaveteliPro::RequestSummaries
  include AlaveteliFeatures::Helpers
  include InfoRequest::TitleValidation

  has_many :info_requests,
           inverse_of: :info_request_batch
  belongs_to :user,
             inverse_of: :info_request_batches,
             counter_cache: true

  has_and_belongs_to_many :public_bodies, -> {
    AlaveteliLocalization.with_locale(AlaveteliLocalization.locale) do
      includes(:translations).
        reorder('public_body_translations.name asc')
    end
  }, inverse_of: :info_request_batches

  attr_accessor :ignore_existing_batch

  validates_presence_of :body
  validates_absence_of :existing_batch,
                       unless: -> { ignore_existing_batch },
                       on: :create

  def self.send_batches
    where(sent_at: nil).find_each do |info_request_batch|
      next unless info_request_batch.user_may_send?

      AlaveteliLocalization.with_locale(info_request_batch.user.locale) do
        info_request_batch.create_batch!
        next unless info_request_batch.all_requests_created?

        InfoRequestBatchMailer.batch_sent(
          info_request_batch,
          info_request_batch.unrequestable_public_bodies,
          info_request_batch.user
        ).deliver_now

        info_request_batch.sent_at = Time.zone.now
        info_request_batch.save!
      end
    end
  end

  def self.with_body(body)
    where("regexp_replace(info_request_batches.body, '[[:space:]]', '', 'g') =
           regexp_replace(?, '[[:space:]]', '', 'g')", body)
  end

  # When constructing a new batch, use this to check user hasn't double
  # submitted.
  def self.find_existing(user, title, body, public_body_ids, id: nil)
    conditions = {
      user_id: user,
      title: title,
      info_request_batches_public_bodies: {
        public_body_id: public_body_ids
      }
    }

    scope = includes(:public_bodies).
      where(conditions).
      with_body(body).
      references(:public_bodies)

    scope = scope.where.not(id: id) if id

    scope.first
  end

  # Create a new batch from the supplied draft version
  def self.from_draft(draft)
    new(user: draft.user,
        public_bodies: draft.public_bodies,
        title: draft.title,
        body: draft.body)
  end

  # Read permission for a batch does not confer permission to read every
  # child.
  def readable_info_requests(ability)
    ids = info_requests.includes(:user).
      select { |request| ability.can?(:read, request) }.map(&:id)
    info_requests.where(id: ids)
  end

  def existing_batch
    self.class.find_existing(user, title, body, public_body_ids, id: id)
  end

  # Creates and sends requests until done or user_may_send? becomes false.
  def create_batch!
    requestable_public_bodies.each do |public_body|
      break unless user_may_send?

      info_request = transaction do
        create_request!(public_body)
      end

      send_request(info_request)

      # Sleep between requests in production, in case we're sending a huge
      # batch which may result in a torrent of auto-replies coming back to
      # us and overloading the server.
      sleep 60 if Rails.env.production?
    end
    reload
  end

  # Reloads user so suspension, closure or untrust takes effect mid-batch.
  def user_may_send?
    user.reload
    Ability.new(user).can?(:create, InfoRequestBatch)
  end

  # Create a FOI request for a public body
  def create_request!(public_body)
    filled_body = OutgoingMessage.fill_in_salutation(body, public_body)
    info_request = InfoRequest.build_from_attributes({ title: title },
                                                     { body: filled_body },
                                                     user)
    info_request.public_body = public_body
    info_request.info_request_batch = self

    info_request.save!
    info_request
  end

  # Send a FOI request to a public body
  def send_request(info_request)
    outgoing_message = info_request.outgoing_messages.first

    mail_message = OutgoingMailer.initial_request(
      outgoing_message.info_request,
      outgoing_message
    ).deliver_now if outgoing_message.sendable?

  rescue *OutgoingMessage.expected_send_errors => e
    outgoing_message.record_email_failure(
      e.message
    )

  else
    outgoing_message.record_email_delivery(
      mail_message.to_addrs.join(', '),
      mail_message.message_id
    )
  end

  # Do we consider the InfoRequestBatch to be sent to all authorities?
  #
  # Returns a Boolean
  def sent?
    sent_at.present?
  end

  # Build an InfoRequest object which is an example of this batch.
  def example_request
    public_body = public_bodies.first
    body = OutgoingMessage.fill_in_salutation(self.body, public_body)
    info_request = InfoRequest.build_from_attributes(
      { title: title, public_body: public_body },
      { body: body },
      user
    )
    info_request
  end

  # What phases are the requests in this batch in
  #
  # Returns unique array of symbols representing phases from InfoRequest::State
  def request_phases
    phases = info_requests.reload.map do |ir|
      if ir.last_event_forming_initial_request_id.nil?
        :awaiting_response
      else
        ir.state.phase
      end
    end
    phases.uniq
  end

  # Summarise the phases requests are in into three groups:
  # in progress, action needed, complete and provide a count of the number of
  # requests in each group.
  #
  # Returns hash of string group names mapped to an integer
  def request_phases_summary(requests = info_requests)
    {
      in_progress: {
        label: _('In progress'),
        count: requests.in_progress.count
      },
      action_needed: {
        label: _('Action needed'),
        count: requests.action_needed.count
      },
      complete: {
        label: _('Complete'),
        count: requests.complete.count
      },
      other: {
        label: _('Other'),
        count: requests.other.count
      }
    }
  end

  # @see RequestSummaries#request_summary_body
  def request_summary_body
    body
  end

  # @see RequestSummaries#request_summary_public_body_names
  def request_summary_public_body_names
    public_bodies.pluck(:name).join(" ")
  end

  # @see RequestSummaries#request_summary_categories
  def request_summary_categories
    categories = []
    if sent_at
      phase_slugs = request_phases.map(&:to_s).uniq
      phases = AlaveteliPro::RequestSummaryCategory.where(slug: phase_slugs)
      categories.concat phases
    else
      # A batch info request which hasn't been sent yet won't show up in the
      # list unless we give it some kind of category, so we fake an awaiting
      # response one
      categories << AlaveteliPro::RequestSummaryCategory.awaiting_response
    end
    categories
  end

  # Return a list of public bodies we've already sent the request to
  #
  # Returns an array of PublicBody objects
  def sent_public_bodies
    PublicBody.where(id: info_requests.map(&:public_body_id))
  end

  # Return a list of public bodies which we can send the request to
  #
  # Returns an array of PublicBody objects
  def requestable_public_bodies
    public_bodies.visible.is_requestable.
      without_tag(PublicBody.batch_excluded_tags) - sent_public_bodies
  end

  # Return a list of public bodies which we can't sent the request to
  #
  # Returns an array of PublicBody objects
  def unrequestable_public_bodies
    allowed = public_bodies.visible.is_requestable.
              without_tag(PublicBody.batch_excluded_tags)
    public_bodies - allowed - sent_public_bodies
  end

  # Have we persisted an InfoRequest for each PublicBody in this batch?
  #
  # Returns a Boolean
  def all_requests_created?
    requestable_public_bodies.empty?
  end

  # Should we summarise the batch request?
  #
  # Returns a Boolean
  def should_summarise?
    request_summary.nil? || all_requests_created?
  end

  # Log an event for all information requests within the batch
  #
  # Returns an array of InfoRequestEvent objects
  def log_event(*args)
    info_requests.map { |request| request.log_event(*args) }
  end

  def prominence
    'normal'
  end

  before_create :request_limits_check

  private

  def request_limits_check
    raise RequestLimits::BatchesOff unless RequestLimits.batches_allowed?(user)

    refused = RequestLimits.batch_size_refusal(public_bodies.size)
    raise RequestLimits::Exceeded, refused if refused
  end
end
