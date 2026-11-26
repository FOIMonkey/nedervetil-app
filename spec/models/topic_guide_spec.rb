require 'spec_helper'

RSpec.describe TopicGuide do
  let(:topic) { Topics::Topic.find('policing') }
  let(:burglaries) do
    topic.questions.find { |question| question.text.include?('burglaries') }
  end
  let(:question_key) { "policing/#{burglaries.slug}" }
  let(:entry) { Topics::Guide.new(topic, 'england').entry(burglaries.slug) }

  it 'needs a source, a question or both' do
    guide = described_class.new(body: 'Open the table.')
    expect(guide).not_to be_valid
    expect(guide.errors[:base]).to include('Pick a source, a question, or both')
  end

  it 'refuses a source or a question the topics don’t have' do
    expect(described_class.new(body: 'x', dataset_id: 'nothing')).
      not_to be_valid
    expect(described_class.new(body: 'x', question_key: 'policing/nothing')).
      not_to be_valid
  end

  it 'needs some words' do
    expect(FactoryBot.build(:topic_guide, body: '')).not_to be_valid
  end

  it 'takes one guide per source, per question, and per source on a question' do
    FactoryBot.create(:topic_guide)
    expect(FactoryBot.build(:topic_guide)).not_to be_valid
    expect(FactoryBot.build(:topic_guide, question_key: question_key)).
      to be_valid
    expect(FactoryBot.build(:topic_guide, dataset_id: nil,
                                          question_key: question_key)).
      to be_valid
  end

  it 'refuses a source on a question it doesn’t answer in any nation' do
    guide = FactoryBot.build(:topic_guide,
                             dataset_id: 'northmoor-abandoned-vehicles',
                             question_key: question_key)
    expect(guide).not_to be_valid
    expect(guide.errors[:dataset_id]).
      to include('doesn’t answer that question in any nation')
  end

  it 'leaves the database to refuse a second guide for one thing' do
    FactoryBot.create(:topic_guide)
    expect { FactoryBot.build(:topic_guide).save(validate: false) }.
      to raise_error(ActiveRecord::RecordNotUnique)
  end

  it 'shows the source’s guide, then the question’s, preferring one for both' do
    source = FactoryBot.create(:topic_guide)
    own = FactoryBot.create(:topic_guide, dataset_id: nil,
                                          question_key: question_key)
    expect(described_class.for(topic, entry)).to eq([source, own])
    both = FactoryBot.create(:topic_guide, question_key: question_key)
    expect(described_class.for(topic, entry)).to eq([source, both])
  end

  it 'leaves drafts out unless asked for them' do
    FactoryBot.create(:topic_guide, published: false)
    expect(described_class.for(topic, entry)).to be_empty
    expect(described_class.for(topic, entry, drafts: true).size).to eq(1)
  end

  it 'says what it is for' do
    guide = FactoryBot.build(:topic_guide, question_key: question_key)
    expect(guide.applies_to).
      to eq("#{burglaries.text}, from #{guide.source.title}")
  end

  it 'is refused when its question went after this request read the topics' do
    page = FactoryBot.create(:topic_page, slug: 'roads')
    question = FactoryBot.create(:topic_question, topic_page: page,
                                                  slug: 'potholes')
    Topics::Topic.find('roads')
    # Gone as another admin's delete would go, after the read above.
    question.delete
    guide = FactoryBot.build(:topic_guide, dataset_id: nil,
                                           question_key: 'roads/potholes')
    expect(guide.save).to be(false)
    expect(guide.errors.full_messages.sole).
      to include('a topic guide needs the question potholes in roads')
    expect(guide).to be_new_record
  end
end
