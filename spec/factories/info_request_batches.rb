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

FactoryBot.define do
  factory :info_request_batch do
    sequence(:title) { |n| "Example Title #{n}" }
    user
    sequence(:body) { |n| "Some text #{n}" }

    # NB order of the traits is important as the after callbacks are run in the
    # order the traits are defined.

    trait :sent do
      transient do
        public_body_count { 1 }
      end

      after(:build) do |batch, evaluator|
        batch.info_requests = build_list(:info_request,
                                         evaluator.public_body_count,
                                         user: batch.user)

        batch.info_requests.each do |request|
          request.info_request_events = [
            build(:sent_event, info_request: request)
          ]
        end

        batch.public_bodies = batch.info_requests.map(&:public_body)
        batch.sent_at = Time.zone.now
      end
    end
  end
end
