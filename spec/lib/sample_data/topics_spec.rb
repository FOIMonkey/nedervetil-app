require 'spec_helper'

RSpec.describe SampleData::Topics do
  let(:tables) do
    [TopicHolder, TopicQuestion, TopicSource, TopicRoute, TopicPage,
     TopicDataset, TopicChange]
  end

  # The suite's topics are the sample's; each example's transaction puts
  # them back.
  before { tables.each(&:delete_all) }

  it 'makes the topics and datasets that readers see' do
    described_class.load!
    expect(Topics::Topic.all.map(&:slug)).to eq(
      %w[streets policing health spending tax homes rivers care]
    )
    burglaries = Topics::Topic.find('policing').questions.first
    expect(burglaries.dataset_for('wales').id).to eq('northmoor-recorded-crime')
    expect(TopicDataset.count).to eq(13)
  end

  it 'leaves a topic or dataset that is already there as it is' do
    described_class.load!
    TopicPage.find_by!(slug: 'policing').update!(title: 'Police')
    TopicPage.find_by!(slug: 'tax').destroy!

    expect { described_class.load! }.
      to change(TopicPage, :count).by(1).
      and change(TopicDataset, :count).by(0)
    expect(TopicPage.find_by!(slug: 'policing').title).to eq('Police')
    expect { described_class.load! }.not_to change(TopicChange, :count)
  end
end
