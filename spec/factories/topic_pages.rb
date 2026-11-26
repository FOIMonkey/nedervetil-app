FactoryBot.define do
  factory :topic_page do
    sequence(:slug) { |n| "roads-#{n}" }
    title { 'Roads' }
    summary { 'Road records' }
    position { 1 }
  end

  factory :topic_holder do
    topic_page
    position { 0 }
    what { 'Potholes and street lights' }
    who { 'Your council' }
    to { { 'tag' => 'council' } }
  end

  factory :topic_question do
    topic_page
    position { 0 }
    text { 'How many potholes were reported?' }
    sequence(:slug) { |n| "potholes-#{n}" }
    ask { { 'tag' => 'council' } }
  end

  factory :topic_source do
    topic_page
    position { 0 }
    label { 'Road statistics' }
    url { 'https://statistics.example/roads' }
  end

  factory :topic_route do
    topic_page
    position { 0 }
    what { 'A pothole to report' }
    route { 'Report it to your council' }
  end

  factory :topic_dataset do
    sequence(:key) { |n| "road-condition-#{n}" }
    publisher { 'Northmoor Statistics Office' }
    title { 'Road condition by council' }
    url { 'https://statistics.example/road-condition' }
    kind { 'table' }
    status { 'official' }
  end
end
