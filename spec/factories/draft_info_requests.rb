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

FactoryBot.define do
  factory :draft_info_request do
    sequence(:title) { |n| "Draft: Example Title #{n}" }
    public_body
    user
    sequence(:body) { |n| "Do you have information about record #{n}?" }
  end
end
