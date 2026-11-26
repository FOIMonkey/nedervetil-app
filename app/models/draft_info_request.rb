# == Schema Information
#
# Table name: draft_info_requests
#
#  id              :integer          not null, primary key
#  title           :string
#  user_id         :integer
#  public_body_id  :integer
#  body            :text
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  journey_context :jsonb            not null
#

# An unsent request draft owned by a user, shown in the inbox until it is
# turned into an InfoRequest or discarded.
class DraftInfoRequest < ApplicationRecord
  include AlaveteliPro::RequestSummaries
  include InfoRequest::DraftTitleValidation

  belongs_to :user,
             inverse_of: :draft_info_requests
  belongs_to :public_body, inverse_of: :draft_info_requests, optional: true

  normalizes :title, :body, with: Whitespace::TRIM_TO_NIL

  # @see RequestSummaries#request_summary_body
  def request_summary_body
    body
  end

  # @see RequestSummaries#request_summary_public_body_names
  def request_summary_public_body_names
    public_body.name unless public_body.blank?
  end

  # @see RequestSummaries#request_summary_categories
  def request_summary_categories
    [AlaveteliPro::RequestSummaryCategory.draft]
  end
end
