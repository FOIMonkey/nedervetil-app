require 'spec_helper'

RSpec.describe TopicRoute do
  it 'says what the route is for and what it is' do
    expect(FactoryBot.build(:topic_route, what: '')).not_to be_valid
    expect(FactoryBot.build(:topic_route, route: '')).not_to be_valid
  end

  it 'links to a search on the other site or a web address' do
    expect(FactoryBot.build(:topic_route, to: { 'wdtk' => 'ombudsman' })).
      to be_valid
    expect(FactoryBot.build(:topic_route, to: { 'url' => 'ombudsman' })).
      not_to be_valid
  end
end
