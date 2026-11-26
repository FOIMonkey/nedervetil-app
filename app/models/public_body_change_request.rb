# == Schema Information
#
# Table name: public_body_change_requests
#
#  id                :integer          not null, primary key
#  user_email        :string
#  user_name         :string
#  user_id           :integer
#  public_body_name  :text
#  public_body_id    :integer
#  public_body_email :string
#  source_url        :text
#  notes             :text
#  is_open           :boolean          default(TRUE), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#

# A visitor or user submission asking admins to add a new PublicBody or update
# an existing authority's email address, with mailer helpers and admin search.
class PublicBodyChangeRequest < ApplicationRecord
  include Searchable

  belongs_to :user,
             inverse_of: :public_body_change_requests,
             counter_cache: true,
             optional: true
  belongs_to :public_body,
             inverse_of: :public_body_change_requests,
             optional: true

  validates_presence_of :public_body_name,
                        message: N_("Please enter the name of the authority"),
                        unless:
                          proc { |change_request| change_request.public_body }
  validates_presence_of :user_name,
                        message: N_("Please enter your name"),
                        unless: proc { |change_request| change_request.user }
  validates_presence_of :user_email,
                        message: N_("Please enter your email address"),
                        unless: proc { |change_request| change_request.user }
  validate :user_email_format,
           unless: proc { |change_request| change_request.user_email.blank? }
  validate :body_email_format,
           unless:
             proc { |change_request| change_request.public_body_email.blank? }
  # Checked only on change so legacy invalid values don't block closing.
  validates :source_url,
            http_url: { message: N_('Please enter a web address, such as ' \
                                    'https://www.example.org, or leave it ' \
                                    'blank') },
            if: :will_save_change_to_source_url?

  scope :new_body_requests, -> {
    where(public_body_id: nil).order(:created_at)
  }
  scope :body_update_requests, -> {
    where.not(public_body_id: nil).order(:created_at)
  }

  singleton_class.undef_method :open # Undefine Kernel.open to avoid warning
  scope :open, -> { where(is_open: true) }

  searchable admin_index: {
    notes: "A",
    public_body_email: "A",
    public_body_name: "A",
    source_url: "A",
    user_email: "A",
    user_name: "A"
  }, root: :public_body

  def self.from_params(params, user)
    change_request = new
    change_request.update_from_params(params, user)
  end

  def update_from_params(params, user)
    if user
      self.user_id = user.id
    else
      self.user_name = params[:user_name]
      self.user_email = params[:user_email]
    end
    self.public_body_name = params[:public_body_name]
    self.public_body_id = params[:public_body_id]
    self.public_body_email = params[:public_body_email]
    self.source_url = params[:source_url]
    self.notes = params[:notes]
    self
  end

  # Returns a safe http/https link, or nil for legacy invalid values.
  def source_link
    HttpUrl.with_default_scheme(source_url)
  end

  def add_body_request?
    public_body ? false : true
  end

  def requester_name
    user ? user.name : user_name
  end

  def requester_email
    user ? user.email : user_email
  end

  def authority_name
    public_body ? public_body.name : public_body_name
  end

  def current_public_body_email
    public_body&.request_email
  end

  def send_message
    mail =
      if add_body_request?
        PublicBodyChangeRequestMailer.add_public_body(self)
      else
        PublicBodyChangeRequestMailer.update_public_body(self)
      end

    mail.deliver_now
  end

  def thanks_notice
    if add_body_request?
      _("Your request to add an authority has been sent. Thank you for " \
        "getting in touch! We'll get back to you soon.")
    else
      _("Your request to update the address for {{public_body_name}} has " \
        "been sent. Thank you for getting in touch! We'll get back to you " \
        "soon.",
        public_body_name: authority_name)
    end
  end

  def send_response(subject, response)
    ContactMailer.from_admin_message(requester_name,
                                     requester_email,
                                     subject,
                                     response.strip).deliver_now
  end

  def comment_for_public_body
    comments = ["Requested by: #{requester_name} (#{requester_email})"]
    comments << "Source URL: #{source_url}" unless source_url.blank?
    comments << "Notes: #{notes}" unless notes.blank?
    comments.join("\n")
  end

  def request_subject
    if add_body_request?
      PlainTextTranslation._("Add authority - {{public_body_name}}",
                             public_body_name: public_body_name)
    else
      PlainTextTranslation._("Update email address - {{public_body_name}}",
                             public_body_name: public_body.name)
    end
  end

  def default_response_subject
    "Re: #{request_subject}"
  end

  def close!
    self.is_open = false
    save!
  end

  private

  def body_email_format
    return if MySociety::Validate.is_valid_email(public_body_email)

    errors.add(:public_body_email,
               _("The authority email doesn't look like a valid address"))
  end

  def user_email_format
    return if MySociety::Validate.is_valid_email(user_email)

    errors.add(:user_email, _("Your email doesn't look like a valid address"))
  end
end
