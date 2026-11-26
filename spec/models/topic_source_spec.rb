require 'spec_helper'

RSpec.describe TopicSource do
  it 'needs a label and a web address' do
    expect(FactoryBot.build(:topic_source, label: '')).not_to be_valid
    expect(FactoryBot.build(:topic_source, url: '')).not_to be_valid
    expect(FactoryBot.build(:topic_source, url: 'javascript:alert(1)')).
      not_to be_valid
  end
end
