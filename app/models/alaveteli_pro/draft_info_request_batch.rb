# == Schema Information
#
# Table name: draft_info_request_batches
#
#  id         :integer          not null, primary key
#  title      :string
#  body       :text
#  user_id    :integer
#  created_at :datetime         not null
#  updated_at :datetime         not null
#

# An unsent batch request draft belonging to a user and its chosen PublicBody
# recipients. Seeds its body from OutgoingMessage::Template::BatchRequest and
# appears in the inbox under the draft category until sent or discarded.
class AlaveteliPro::DraftInfoRequestBatch < ApplicationRecord
  include AlaveteliPro::RequestSummaries
  include InfoRequest::DraftTitleValidation

  belongs_to :user,
             inverse_of: :draft_info_request_batches
  has_and_belongs_to_many :public_bodies, -> {
    AlaveteliLocalization.with_locale(AlaveteliLocalization.locale) do
      includes(:translations).preload(:tags).
        reorder('public_body_translations.name asc')
    end
  }, inverse_of: :draft_info_request_batches

  after_initialize :set_default_body

  def set_default_body
    return unless body.blank?

    template = OutgoingMessage::Template::BatchRequest.new
    template_options = {}
    template_options[:info_request_title] = title if title
    self.body = template.body(template_options)
    self.body += user.name if user
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
    [AlaveteliPro::RequestSummaryCategory.draft]
  end
end
