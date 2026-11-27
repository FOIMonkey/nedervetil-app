# == Schema Information
#
# Table name: public_bodies
#
#  id                                     :integer          not null, primary key
#  version                                :integer          not null
#  last_edit_editor                       :string           not null
#  last_edit_comment                      :text
#  created_at                             :datetime         not null
#  updated_at                             :datetime         not null
#  home_page                              :text
#  name                                   :text
#  short_name                             :text
#  request_email                          :text
#  url_name                               :text
#  first_letter                           :string
#  publication_scheme                     :text
#  disclosure_log                         :text
#

require 'securerandom'

# A public authority that can receive FOI requests. Stores versioned and
# translated contact details, links, tags, notes and censor rules, and indexes
# public and admin search fields.
class PublicBody < ApplicationRecord
  include Rails.application.routes.url_helpers
  include LinkToHelper

  include Categorisable
  include Searchable
  include Taggable
  include Notable

  include PublicBody::CalculatedHomePage
  include PublicBody::CsvImport

  admin_columns exclude: %i[name last_edit_editor]

  def self.admin_title
    'Authority'
  end

  # Any PublicBody tagged with any of the follow tags won't be returned in the
  # batch authority search results or batch category UI
  cattr_accessor :batch_excluded_tags,
                 instance_accessor: false,
                 default: %w[defunct foi_no not_apply]

  has_many :info_requests,
           -> { order(created_at: :desc) },
           inverse_of: :public_body
  has_many :censor_rules,
           -> { order(created_at: :desc) },
           as: :censorable,
           inverse_of: :censorable,
           dependent: :destroy
  has_many :public_body_change_requests,
           -> { order(created_at: :desc) },
           inverse_of: :public_body,
           dependent: :destroy
  has_many :draft_info_requests,
           -> { order(created_at: :desc) },
           inverse_of: :public_body

  has_and_belongs_to_many :info_request_batches,
                          inverse_of: :public_bodies
  has_and_belongs_to_many :draft_info_request_batches,
                          class_name: 'AlaveteliPro::DraftInfoRequestBatch',
                          inverse_of: :public_bodies

  validates_presence_of :name, message: N_("Name can't be blank")
  validates_presence_of :url_name, message: N_("URL name can't be blank")
  validates_presence_of :last_edit_editor,
                        message: N_("Last edit editor can't be blank")

  validates :request_email,
            not_nil: { message: N_("Request email can't be nil") }

  validates_uniqueness_of :short_name,
                          message: N_("Short name is already taken"),
                          allow_blank: true
  validates_uniqueness_of :url_name, message: N_("URL name is already taken")
  validates_uniqueness_of :name, message: N_("Name is already taken")

  validates :last_edit_editor,
            length: { maximum: 255,
                      too_long: N_("Last edit editor can't be longer than " \
                                   "255 characters") }

  validate :request_email_if_requestable

  # Checked only on change so legacy invalid values don't block unrelated
  # saves; invalid stored values are still never linked.
  validates :home_page,
            http_url: { message: N_('Home page must be a web address, ' \
                                    'such as https://www.example.org') },
            if: :will_save_change_to_home_page?

  PUBLICATION_SCHEME_MESSAGE =
    N_('Publication scheme must be a web address, such as ' \
       'https://www.example.org')
  DISCLOSURE_LOG_MESSAGE =
    N_('Disclosure log must be a web address, such as ' \
       'https://www.example.org')

  # Validated on change here (current locale/CSV) and on Translation (admin
  # translation fields).
  validates :publication_scheme,
            http_url: { message: PUBLICATION_SCHEME_MESSAGE },
            if: -> { changed.include?('publication_scheme') }
  validates :disclosure_log,
            http_url: { message: DISCLOSURE_LOG_MESSAGE },
            if: -> { changed.include?('disclosure_log') }

  after_save :update_auto_applied_tags

  after_update :expire_requests_on_rename

  # Every public body except for the internal admin one is visible
  scope :visible, -> {
    where("public_bodies.id <> #{ PublicBody.internal_admin_body.id }")
  }

  include PublicBody::Versioned

  normalizes :last_edit_editor, :last_edit_comment, :home_page,
             with: Whitespace::TRIM_TO_NIL

  translates :name, :short_name, :request_email, :url_name, :first_letter,
             :publication_scheme, :disclosure_log

  # Globalize stashes translated writes outside `normalizes` until save;
  # normalise them before validation so callbacks see stored values.
  before_validation :normalize_unsaved_translations

  searchable index: {
               ".name_for_index": "A",
               ".short_name_for_index": "A",
               home_page: "B",
               ".notes_for_index": "C",
               ".disclosure_log": "D",
               ".publication_scheme": "D"
             },
             admin_index: {
               ".request_email": "A",
               last_edit_editor: "D",
               last_edit_comment: "D"
             }

  # Cannot be grouped at top as it depends on the `translates` macro
  include Translatable

  # Cannot be grouped at top as it depends on the `translates` macro
  include PublicBodyDerivedFields

  # Cannot be grouped at top as it depends on the `translates` macro
  class Translation
    include PublicBodyDerivedFields
    normalizes :locale, :name, :short_name, :url_name, :first_letter,
               :publication_scheme, :disclosure_log,
               with: Whitespace::TRIM_TO_NIL
    normalizes :request_email, with: Whitespace::TRIM

    validates :publication_scheme,
              http_url: { message: PUBLICATION_SCHEME_MESSAGE },
              if: :will_save_change_to_publication_scheme?
    validates :disclosure_log,
              http_url: { message: DISCLOSURE_LOG_MESSAGE },
              if: :will_save_change_to_disclosure_log?
  end

  # Returns a safe http/https link, or nil for legacy invalid values.
  def publication_scheme_link
    HttpUrl.with_default_scheme(publication_scheme)
  end

  def disclosure_log_link
    HttpUrl.with_default_scheme(disclosure_log)
  end

  def name_for_index
    Searchable.without_apostrophes(name)
  end

  def short_name_for_index
    Searchable.without_apostrophes(short_name)
  end

  def notes_for_index
    Searchable.without_apostrophes(notes_as_string)
  end

  # Public: Search for Public Bodies whose name, short_name, request_email or
  # tags contain the given query
  #
  # query  - String to query the searchable fields
  # locale - String to specify the language of the search query
  #          (default: AlaveteliLocalization.locale)
  #
  # Returns an ActiveRecord::Relation
  def self.search(query, locale = AlaveteliLocalization.locale)
    sql = <<-SQL
    (
      lower(public_body_translations.name) like lower('%'||?||'%')
      OR lower(public_body_translations.short_name) like lower('%'||?||'%')
      OR lower(public_body_translations.request_email) like lower('%'||?||'%' )
      OR lower(has_tag_string_tags.name) like lower('%'||?||'%' )
    )
    AND has_tag_string_tags.model_id = public_bodies.id
    AND has_tag_string_tags.model_type = 'PublicBody'
    AND (public_body_translations.locale = ?)
    SQL

    PublicBody.joins(:translations, :tags).
      where([sql, query, query, query, query, locale]).
      uniq
  end

  def self.with_domain(domain)
    return none unless domain

    with_translations(AlaveteliLocalization.locale).
      where("lower(public_body_translations.request_email) " \
            "like lower('%'||?||'%')", domain).
        merge(PublicBody::Translation.order(:name))
  end

  def self.find_by_name(name)
    find_by(name: name)
  end

  def self.find_by_url_name(url_name)
    find_by(url_name: url_name)
  end

  # like find_by_url_name but also search historic url_name if none found
  def self.find_by_url_name_with_historic(name)
    # If many bodies are found (usually because the url_name is the same
    # across locales) return any of them.
    found = joins(:translations).
      where(public_body_translations: { url_name: name }).
      readonly(false).
      first

    return found if found

    # If none found, then search the history of short names and find unique
    # public bodies in it
    old = PublicBody::Version.
      where(url_name: name).
      distinct.
      pluck(:public_body_id)

    # Maybe return the first one, so we show something relevant,
    # rather than throwing an error?
    if old.size > 1
      raise "Two bodies with the same historical URL name: #{name}"
    end
    return unless old.size == 1

    PublicBody.find(old.first)
  end

  def self.without_request_email
    joins(:translations).
      where(public_body_translations: { request_email: '' }).
      not_defunct
  end

  def self.with_request_email
    joins(:translations).
      where.not(public_body_translations: { request_email: '' })
  end

  # If tagged "not_apply", then FOI/EIR no longer applies to authority at all
  # and the site will not accept further requests for them
  def not_apply?
    has_tag?('not_apply')
  end

  scope :foi_applies, -> { without_tag('not_apply') }

  # If tagged "foi_no", then the authority is not subject to FOI law but
  # requests may still be made through the site (e.g. they may have agreed to
  # respond to requests on a voluntary basis)
  # This will apply in all cases if the site has been configured not to state
  # that authorities have a legal obligation
  def not_subject_to_law?
    has_tag?('foi_no') || !AlaveteliConfiguration.authority_must_respond
  end

  # If tagged "defunct", then the authority no longer exists at all
  def defunct?
    has_tag?('defunct')
  end

  scope :not_defunct, -> { without_tag('defunct') }

  # Are all requests to this body under the Environmental Information
  # Regulations?
  def eir_only?
    has_tag?('eir_only')
  end

  def site_administration?
    has_tag?('site_administration')
  end

  def internal_admin_body?
    url_name == 'internal_admin_authority'
  end

  # Can an FOI (etc.) request be made to this body?
  def is_requestable?
    has_request_email? && !defunct? && !not_apply? && !internal_admin_body?
  end

  scope :is_requestable, -> {
    visible.with_request_email.not_defunct.foi_applies
  }

  # Strict superset of is_requestable?
  def is_followupable?
    has_request_email?
  end

  def has_request_email?
    !request_email.blank? && request_email != 'blank'
  end

  # Also used as not_followable_reason
  def not_requestable_reason
    if defunct?
      'defunct'
    elsif not_apply? || internal_admin_body?
      'not_apply'
    elsif !has_request_email?
      'bad_contact'
    else
      raise "not_requestable_reason called with type that has no reason"
    end
  end

  def special_not_requestable_reason?
    defunct? || not_apply?
  end

  def legislations
    @legislations ||= Legislation.for_public_body(self)
  end

  def legislation
    legislations.first
  end

  # The "internal admin" is a special body for internal use.
  def self.internal_admin_body
    matching_pbs = AlaveteliLocalization.
      with_locale(AlaveteliLocalization.default_locale) do
      default_scoped.where(url_name: 'internal_admin_authority')
    end

    if matching_pbs.empty?
      # "internal admin" exists but has the wrong default locale - fix & return
      if (invalid_locale = PublicBody::Translation.
                             find_by_url_name('internal_admin_authority'))
        found_pb = PublicBody.find(invalid_locale.public_body_id)
        AlaveteliLocalization.
          with_locale(AlaveteliLocalization.default_locale) do
          found_pb.name = "Internal admin authority"
          found_pb.request_email = AlaveteliConfiguration.contact_email
          found_pb.save!
        end
        found_pb
      else
        AlaveteliLocalization.
          with_locale(AlaveteliLocalization.default_locale) do
          default_scoped.
            create!(name: 'Internal admin authority',
                    short_name: "",
                    request_email: AlaveteliConfiguration.contact_email,
                    home_page: nil,
                    publication_scheme: nil,
                    last_edit_editor: "internal_admin",
                    last_edit_comment: "Made by PublicBody.internal_admin_body")
        end
      end
    elsif matching_pbs.length == 1
      matching_pbs[0]
    else
      raise "Multiple public bodies (#{matching_pbs.length}) found with " \
            "url_name 'internal_admin_authority'"
    end
  end

  def request_email
    if AlaveteliConfiguration.override_all_public_body_request_emails.blank? ||
       read_attribute(:request_email).blank?
      read_attribute(:request_email)
    else
      AlaveteliConfiguration.override_all_public_body_request_emails
    end
  end

  # Domain name of the request email
  def request_email_domain
    PublicBody.extract_domain_from_email(request_email)
  end

  # Return the canonicalised domain part of an email address
  #
  # TODO: Extract to library class
  def self.extract_domain_from_email(email)
    match = /@(.*)/.match(email)
    match && match[1].downcase
  end

  def notes
    Note.sort(all_notes)
  end

  def notes_as_string
    notes.map(&:to_plain_text).join(' ')
  end

  def has_notes?
    notes.present?
  end

  def expire_requests
    InfoRequest::ExpireJob.perform_later(self, :info_requests)
  end

  class << self
    alias original_with_tag with_tag
  end

  def self.with_tag(tag)
    return all if tag.size == 1 || tag.nil? || tag == 'all'

    if tag == 'other'
      tags = PublicBody.category_list.distinct.
        where.not(category_tag: [nil, '', 'other']).
        pluck(:category_tag)
      where.not("EXISTS(#{tag_search_sql(tags)})")
    else
      original_with_tag(tag)
    end
  end

  def self.with_query(query, tag)
    like_query = "%#{query}%"
    has_first_letter = tag.size == 1

    underscore_locale = AlaveteliLocalization.locale
    underscore_default_locale = AlaveteliLocalization.default_locale
    where_parameters = {
      locale: underscore_locale,
      query: like_query,
      first_letter: tag
    }

    if AlaveteliConfiguration.public_body_list_fallback_to_default_locale
      # Unfortunately, when we might fall back to the
      # default locale, this is a rather complex query:
      if DatabaseCollation.supports?(underscore_locale)
        select_sql = "public_bodies.*, " \
                     "COALESCE(current_locale.name, default_locale.name) " \
                     "COLLATE \"#{underscore_locale}\" AS display_name"
      else
        select_sql = "public_bodies.*, " \
                     "COALESCE(current_locale.name, default_locale.name) " \
                     "AS display_name"
      end

      select(select_sql).
        joins(
          "LEFT OUTER JOIN public_body_translations as current_locale ON " \
          "(public_bodies.id = current_locale.public_body_id AND " \
          "current_locale.locale = '#{sanitize_sql(underscore_locale)}')"
        ).
        joins(
          "LEFT OUTER JOIN public_body_translations as default_locale ON " \
          "(public_bodies.id = default_locale.public_body_id AND " \
          "default_locale.locale = " \
          "'#{sanitize_sql(underscore_default_locale)}')"
        ).
        # rubocop:disable Layout/LineLength -- interpolated SQL
        where("(#{get_public_body_list_translated_condition('current_locale', has_first_letter)}) OR " \
              "(#{get_public_body_list_translated_condition('default_locale', has_first_letter)}) ", where_parameters).
        # rubocop:enable Layout/LineLength
        where('COALESCE(current_locale.name, default_locale.name) IS NOT NULL').
        order(:display_name)
    else
      # The simpler case where we're just searching in the current locale:
      where_condition = get_public_body_list_translated_condition(
        'public_body_translations', has_first_letter, true
      )

      if DatabaseCollation.supports?(underscore_locale)
        where(where_condition, where_parameters).
          joins(:translations).
          order(
            Arel.sql(
              %Q(public_body_translations.name COLLATE "#{underscore_locale}")
            )
          )
      else
        where(where_condition, where_parameters).
          joins(:translations).
            merge(PublicBody::Translation.order(:name))
      end
    end
  end

  def questions
    PublicBodyQuestion.fetch(self)
  end

  private

  def normalize_unsaved_translations
    globalize.stash.each_value do |values|
      values.each do |name, value|
        values[name] = Translation.normalize_value_for(name, value)
      end
    end
  end

  # A request's pages carry the authority's URL name.
  def expire_requests_on_rename
    expire_requests if saved_change_to_attribute?(:url_name)
  end

  # Read an attribute value (without using locale fallbacks if the
  # attribute is translated)
  def read_attribute_value(name, locale)
    if self.class.translated?(name.to_sym)
      if globalize.stash.contains?(locale, name)
        globalize.stash.read(locale, name)
      else
        translation_for(locale).send(name)
      end
    else
      send(name)
    end
  end

  def request_email_if_requestable
    # Request_email can be blank, meaning we don't have details
    return unless is_requestable?
    return if MySociety::Validate.is_valid_email(request_email)

    errors.add(:request_email,
               "Request email doesn't look like a valid email address")
  end

  def self.get_public_body_list_translated_condition(table, has_first_letter = false, locale = nil)
    result = "(upper(#{table}.name) LIKE upper(:query)" \
      " OR upper(#{table}.short_name) LIKE upper(:query))"
    result += " AND #{table}.first_letter = :first_letter" if has_first_letter
    result += " AND #{table}.locale = :locale" if locale
    result
  end
  private_class_method :get_public_body_list_translated_condition

  def update_auto_applied_tags
    update_missing_email_tag
  end

  def update_missing_email_tag
    if missing_email? && !defunct?
      add_tag_if_not_already_present('missing_email')
    else
      remove_tag('missing_email')
    end
  end

  def missing_email?
    !has_request_email?
  end
end
