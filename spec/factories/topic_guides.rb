FactoryBot.define do
  factory :topic_guide do
    dataset_id { 'northmoor-recorded-crime' }
    body { '<p>Open the table and find your area.</p>' }
    published { true }
  end
end
