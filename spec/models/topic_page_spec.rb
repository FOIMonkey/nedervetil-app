require 'spec_helper'

RSpec.describe TopicPage do
  it 'needs an address-shaped slug that no other page has' do
    expect(FactoryBot.build(:topic_page, slug: 'Roads and streets')).
      not_to be_valid
    FactoryBot.create(:topic_page, slug: 'roads')
    expect(FactoryBot.build(:topic_page, slug: 'roads')).not_to be_valid
  end

  it 'keeps its slug once created' do
    page = FactoryBot.create(:topic_page, slug: 'roads')
    page.slug = 'streets'
    expect(page).not_to be_valid
    expect(page.errors[:slug]).to be_present
  end

  it 'needs a title and a summary' do
    expect(FactoryBot.build(:topic_page, title: '')).not_to be_valid
    expect(FactoryBot.build(:topic_page, summary: '')).not_to be_valid
  end

  it 'takes its own titles for nations only' do
    expect(FactoryBot.build(:topic_page, titles: { 'wales' => 'Ffyrdd' })).
      to be_valid
    expect(FactoryBot.build(:topic_page, titles: { 'france' => 'Routes' })).
      not_to be_valid
  end

  it 'lists documents by public id' do
    expect(FactoryBot.build(:topic_page, documents: ['abcdefghjk23'])).
      to be_valid
    expect(FactoryBot.build(:topic_page, documents: ['17'])).not_to be_valid
  end

  describe '.topics' do
    let(:page) do
      FactoryBot.create(:topic_page, slug: 'roads',
                                     titles: { 'wales' => 'Ffyrdd' })
    end

    it 'gives readers the topic its rows describe' do
      FactoryBot.create(:topic_holder, topic_page: page, who: 'Your council')
      FactoryBot.create(:topic_holder, topic_page: page, position: 1,
                                       who: 'Caledon Roads',
                                       nations: ['scotland'])
      FactoryBot.create(:topic_question, topic_page: page, position: 1,
                                         slug: 'second')
      FactoryBot.create(:topic_question,
                        topic_page: page, slug: 'first',
                        dataset: { 'wales' => 'northmoor-recorded-crime' })
      topic = described_class.where(id: page).topics.sole

      expect(topic.slug).to eq('roads')
      expect(topic.title_for('wales')).to eq('Ffyrdd')
      expect(topic.title_for('england')).to eq('Roads')
      expect(topic.questions.map(&:slug)).to eq(%w[first second])
      expect(topic.questions.first.dataset_for('wales')&.id).
        to eq('northmoor-recorded-crime')
      expect(topic.questions.first.dataset_for('england')).to be_nil
      expect(Topics::Guide.new(topic, 'england').holders.map(&:who)).
        to eq(['Your council'])
      expect(Topics::Guide.new(topic, 'scotland').holders.map(&:who)).
        to eq(['Your council', 'Caledon Roads'])
    end

    it 'puts the topics in order' do
      FactoryBot.create(:topic_page, slug: 'second', position: 2)
      FactoryBot.create(:topic_page, slug: 'first', position: 1)
      expect(described_class.topics.map(&:slug) & %w[second first]).
        to eq(%w[first second])
    end
  end

  describe 'deleting' do
    let(:page) { FactoryBot.create(:topic_page, slug: 'roads') }

    it 'takes its rows, even a holder its questions name' do
      holder = FactoryBot.create(:topic_holder, topic_page: page, key: 'roads')
      FactoryBot.create(:topic_question, topic_page: page,
                                         holder: { 'england' => 'roads' })
      expect(page.destroy).to be_truthy
      expect(TopicHolder.exists?(holder.id)).to be(false)
      expect(TopicQuestion.where(topic_page_id: page.id)).to be_empty
    end

    it 'stays while a topic guide names it' do
      FactoryBot.create(:topic_holder, topic_page: page)
      FactoryBot.create(:topic_question, topic_page: page, slug: 'potholes')
      FactoryBot.create(:topic_guide, dataset_id: nil, topic_slug: 'roads',
                                      question_slug: 'potholes')
      expect(page.destroy).to be(false)
      expect(page.errors.full_messages.sole).
        to include('a topic guide needs the question potholes in roads')
      expect(page.reload.holders.count).to eq(1)
    end
  end

  describe 'matching documents to its search words' do
    let!(:page) { FactoryBot.create(:topic_page, search: 'potholes') }
    let(:job) { Disclosures::TopicMatchJob }

    it 'matches them again when a page comes, goes or changes its words' do
      expect { FactoryBot.create(:topic_page) }.to have_enqueued_job(job)
      expect { page.update!(search: 'potholes OR craters') }.
        to have_enqueued_job(job)
      expect { page.destroy! }.to have_enqueued_job(job)
    end

    it 'leaves them for other changes, and for a write that rolls back' do
      expect { page.update!(title: 'Potholes') }.not_to have_enqueued_job(job)
      expect do
        described_class.transaction do
          FactoryBot.create(:topic_page)
          raise ActiveRecord::Rollback
        end
      end.not_to have_enqueued_job(job)
    end
  end
end
