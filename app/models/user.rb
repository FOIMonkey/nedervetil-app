# == Schema Information
#
# Table name: users
#
#  id                                :integer          not null, primary key
#  email                             :string           not null
#  name                              :string           not null
#  hashed_password                   :string           default(""), not null
#  salt                              :string
#  created_at                        :datetime         not null
#  updated_at                        :datetime         not null
#  email_confirmed                   :boolean          default(FALSE), not null
#  url_name                          :text             not null
#  last_daily_track_email            :datetime
#  ban_text                          :text             default(""), not null
#  locale                            :string
#  email_bounced_at                  :datetime
#  email_bounce_message              :text             default(""), not null
#  trusted                           :boolean          default(FALSE), not null
#  receive_email_alerts              :boolean          default(TRUE), not null
#  otp_enabled                       :boolean          default(FALSE), not null
#  otp_secret_key                    :string
#  otp_counter                       :integer
#  confirmed_not_spam                :boolean          default(FALSE), not null
#  info_requests_count               :integer          default(0), not null
#  request_classifications_count     :integer          default(0), not null
#  public_body_change_requests_count :integer          default(0), not null
#  info_request_batches_count        :integer          default(0), not null
#  daily_summary_hour                :integer
#  daily_summary_minute              :integer
#  closed_at                         :datetime
#  login_token                       :string
#  status_update_count               :integer          default(0), not null
#  last_sign_in_at                   :datetime
#  otp_last_used_at                  :integer
#  otp_enabled_at                    :datetime
#  otp_backup_codes_generated_at     :datetime
#  otp_backup_codes                  :text
#  encrypted_password                :string           default(""), not null
#  reset_password_token              :string
#  reset_password_sent_at            :datetime
#  confirmation_token                :string
#  confirmation_sent_at              :datetime
#  confirmed_at                      :datetime
#  unconfirmed_email                 :string
#  otp_secret                        :text
#  consumed_timestep                 :bigint
#  otp_required_for_login            :boolean          default(FALSE), not null
#  devise_otp_backup_codes           :string           default([]), not null, is an Array
#  authentication_version            :string           default(""), not null
#  credential_reset_required         :boolean          default(FALSE), not null
#

# A registered account. Owns requests, drafts, batches, notifications, roles
# and authentication records; supports Devise credentials, banning, closing,
# anonymisation, erasure and admin-only search.
class User < ApplicationRecord
  include Rails.application.routes.url_helpers
  include LinkToHelper

  include Searchable
  include Taggable

  include AlaveteliFeatures::Helpers
  include AlaveteliPro::PhaseCounts

  include User::Anonymisable
  include User::Authentication
  include User::Erasable
  include User::InternalAdmin
  include User::LimitedProfile
  include User::Slug
  include User::SpreadableAlerts
  include User::Unused

  has_and_belongs_to_many :roles,
                          -> { site_wide },
                          join_table: :users_roles,
                          after_add: :assign_role_features,
                          after_remove: :assign_role_features

  # Users with any of the named roles. A subquery rather than a join, so it
  # chains onto sorted and paginated scopes without duplicating rows.
  scope :with_any_role, -> (*names) {
    where(id: unscoped.joins(:roles).
                where(roles: { name: names.map(&:to_s) }).
                select(:id))
  }
  scope :with_role, -> (name) { with_any_role(name) }

  # Every text column but otp_backup_codes, which is an alias for the array
  # devise_otp_backup_codes.
  normalizes :email, :name, :hashed_password, :salt, :url_name, :ban_text,
             :locale, :email_bounce_message, :otp_secret_key, :login_token,
             :encrypted_password, :reset_password_token, :confirmation_token,
             :unconfirmed_email, :otp_secret, :authentication_version,
             with: Whitespace::TRIM

  admin_columns exclude: [:hashed_password, :salt,
                          :login_token, :encrypted_password,
                          :reset_password_token,
                          :confirmation_token, :otp_secret,
                          :devise_otp_backup_codes,
                          :authentication_version,
                          :otp_secret_key, :otp_counter, :otp_backup_codes,
                          :url_name]

  has_many :authentication_returns, dependent: :delete_all
  has_many :authentication_enrolments, dependent: :delete_all
  has_many :pending_email_changes, dependent: :delete_all
  has_many :pending_request_drafts, foreign_key: :intended_user_id,
                                    dependent: :delete_all

  has_many :info_requests,
           -> { order(created_at: :desc) },
           inverse_of: :user,
           dependent: :destroy
  has_many :info_request_events,
           -> { reorder(created_at: :desc) },
           through: :info_requests
  has_many :incoming_messages,
           through: :info_requests
  has_many :foi_attachments,
           through: :incoming_messages
  has_many :outgoing_messages,
           inverse_of: :user,
           through: :info_requests
  has_many :draft_info_requests,
           -> { order(created_at: :desc) },
           inverse_of: :user,
           dependent: :destroy
  has_many :user_info_request_sent_alerts,
           inverse_of: :user,
           dependent: :destroy
  has_many :post_redirects,
           -> { order(created_at: :desc) },
           inverse_of: :user,
           dependent: :destroy
  has_many :public_body_change_requests,
           -> { order(created_at: :desc) },
           inverse_of: :user,
           dependent: :destroy
  has_many :censor_rules,
           -> { order(created_at: :desc) },
           as: :censorable,
           inverse_of: :censorable,
           dependent: :destroy
  has_many :info_request_batches,
           -> { order(created_at: :desc) },
           inverse_of: :user,
           dependent: :destroy
  has_many :draft_info_request_batches,
           -> { order(created_at: :desc) },
           inverse_of: :user,
           dependent: :destroy,
           class_name: 'AlaveteliPro::DraftInfoRequestBatch'
  has_many :request_classifications,
           inverse_of: :user,
           dependent: :destroy
  has_many :request_summaries,
           inverse_of: :user,
           dependent: :destroy,
           class_name: 'AlaveteliPro::RequestSummary'
  has_many :notifications,
           inverse_of: :user,
           dependent: :destroy
  has_many :announcements,
           inverse_of: :user
  has_many :announcement_dismissals,
           inverse_of: :user,
           dependent: :destroy

  has_many :sign_ins,
           class_name: 'User::SignIn',
           inverse_of: :user,
           dependent: :destroy

  has_many :email_histories,
           -> { order(changed_at: :desc) },
           class_name: 'User::EmailHistory',
           inverse_of: :user,
           dependent: :destroy

  has_many :permission_changes,
           -> { order(created_at: :desc, id: :desc) },
           class_name: 'User::PermissionChange',
           inverse_of: :user,
           dependent: :destroy

  scope :active, -> { not_banned.not_closed }
  scope :banned, -> { where.not(ban_text: '') }
  scope :not_banned, -> { where(ban_text: '') }
  scope :closed, -> { where.not(closed_at: nil) }
  scope :not_closed, -> { where(closed_at: nil) }

  validates_presence_of :name, message: _('Please enter your name')

  validate :name_is_not_email

  after_update :expire_requests_on_rename

  searchable admin_index: {
    email: "A",
    name: "A",
    url_name: "A",
    ban_text: "A"
  }

  def self.legacy_search(query)
    sql = <<~SQL
      users.name ILIKE '%'||:query||'%' OR
      users.email ILIKE '%'||:query||'%' OR
      has_tag_string_tags.name ILIKE :query
    SQL

    left_outer_joins(:tags).
      where(sql, query: query).
      distinct
  end

  # Case-insensitively find a user from their email
  def self.find_user_by_email(email)
    return nil if email.blank?

    where('lower(email) = lower(?)', email.strip).first
  end

  # Reads the user's roles once: a page can ask dozens of times.
  def has_role?(name)
    roles.any? { |role| role.name == name.to_s }
  end

  def is_admin?
    has_role?(:admin)
  end

  # Raises for a name outside Role.allowed_roles.
  def add_role(name)
    role = Role.site_wide.find_or_create_by!(name: name.to_s)
    roles << role unless roles.include?(role)
    role
  end

  def remove_role(name)
    roles.delete(roles.select { |role| role.name == name.to_s })
  end

  def self.record_bounce_for_email(email, message)
    user = User.find_user_by_email(email)
    return if user.nil?

    user.record_bounce(message) if user.email_bounced_at.nil?
  end

  # Canonical check for admin powers (suspended/closed admins have none);
  # is_admin? checks the role alone.
  def active_admin?
    active? && is_admin?
  end

  def transactions(*associations)
    opts = {}
    opts[:transaction_associations] = associations if associations.any?
    TransactionCalculator.new(self, opts)
  end

  # A request's pages carry the requester's URL name.
  def expire_requests_on_rename
    return unless saved_change_to_attribute?(:url_name)

    expire_requests
  end

  def expire_requests
    InfoRequest::ExpireJob.perform_later(self, :info_requests)
  end

  def locale
    (super || AlaveteliLocalization.locale).to_s
  end

  def name
    name = read_attribute(:name)
    name = _('{{user_name}} (Account suspended)', user_name: name) if suspended?
    name
  end

  # When name is changed, also change the url name
  def name=(name)
    write_attribute(:name, name.try(:strip))
  end

  def previous_names
    outgoing_messages.unscope(:order).
      distinct(:from_name).
      where.not(from_name: read_attribute(:name)).
      pluck(:from_name)
  end

  # For use in to/from in email messages
  def name_and_email
    MailHandler.address_from_name_and_email(name, email)
  end

  def can_admin_roles
    roles.
      flat_map { |role| Role.grants_and_revokes(role.name.to_sym) }.
      compact.
      uniq
  end

  def can_admin_role?(role)
    can_admin_roles.include?(role)
  end

  def banned?
    ban_text.present?
  end

  def close
    close!
  rescue ActiveRecord::RecordInvalid
    false
  end

  def close!
    update!(
      closed_at: Time.zone.now,
      receive_email_alerts: false,
      login_token: nil
    )
  end

  def closed?
    closed_at.present?
  end

  def close_and_anonymise(editor:, reason:)
    transaction do
      close!
      anonymise!
      erase!(editor: editor, reason: reason)
    end
  end

  def active?
    !banned? && !closed?
  end

  def suspended?
    !active?
  end

  # Used by Admin::LinkHelper#user_both_links to mark banned accounts.
  def prominence
    banned? ? 'hidden' : 'normal'
  end

  # Exempt from sending limits and allowed to send batches. Prefer this over
  # the :trusted column, which stores only the admin tick.
  def trusted?
    self[:trusted] || active_admin? || internal_admin_user?
  end

  # Legacy writer alias used by theme specs; intentionally no reader.
  def no_limit=(value)
    self.trusted = value
  end

  def can_fail_html
    if banned?
      text = ban_text.strip
    elsif closed?
      text = _('Account closed at user request')
    else
      raise 'Unknown reason for ban'
    end
    text = CGI.escapeHTML(text)
    text = MySociety::Format.make_clickable(text, contract: 1)
    text = text.gsub(/\n/, '<br>')
    # rubocop:disable Rails/OutputSafety -- the ban text was escaped above; only links and line breaks were added since
    text.html_safe
    # rubocop:enable Rails/OutputSafety
  end

  # Returns domain part of user's email address
  def email_domain
    PublicBody.extract_domain_from_email(email)
  end

  def record_bounce(message)
    update!(
      email_bounced_at: Time.zone.now,
      email_bounce_message: convert_string_to_utf8(message).string
    )
  end

  # Notify a user about an info_request_event, allowing the user's preferences
  # to determine how that notification is delivered.
  def notify(info_request_event)
    Notification.create(
      info_request_event: info_request_event,
      frequency: Notification.frequencies[notification_frequency],
      user: self
    )
  end

  # Return a timestamp for the next time a user should be sent a daily summary
  def next_daily_summary_time
    summary_time = Time.zone.now.change(daily_summary_time)
    summary_time += 1.day if summary_time < Time.zone.now
    summary_time
  end

  def daily_summary_time
    { hour: daily_summary_hour,
      min: daily_summary_minute }
  end

  # Daily summary unless opted into instant email; lookup failures must raise
  # rather than falling back to another frequency.
  def notification_frequency
    if IncomingAttention::InstantEmails.on?(self)
      Notification::INSTANTLY
    else
      Notification::DAILY
    end
  end

  def features
    # Will return enabled and disabled features. Call #enabled? to see the
    # current state
    AlaveteliFeatures.features.with_actor(self)
  end

  def features=(new_features)
    features.assign_features(new_features)
  end

  # Define an id number for use with the Flipper gem's user-by-user feature
  # flagging. We prefix with the class because features can be enabled for
  # other types of objects (e.g Roles) in the same way and will be stored in
  # the same table. See:
  # https://github.com/jnunemaker/flipper/blob/master/docs/Gates.md
  def flipper_id
    "User;#{id}"
  end

  def record_sign_in(*args)
    sign_ins.create(*args) if User::SignIn.retain_signins?
    touch(:last_sign_in_at)
  end

  private

  def name_is_not_email
    return unless MySociety::Validate.is_valid_email(name)

    errors.add(
      :name,
      _("Please enter your name, not your email address, in the name field.")
    )
  end

  def assign_role_features(_role)
    features.assign_role_features
  end
end
