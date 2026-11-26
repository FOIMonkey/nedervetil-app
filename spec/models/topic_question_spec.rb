require 'spec_helper'

RSpec.describe TopicQuestion do
  let(:page) { FactoryBot.create(:topic_page) }

  def question(**attributes)
    FactoryBot.build(:topic_question, topic_page: page, **attributes)
  end

  it 'needs words and an address-shaped slug that isn’t reserved' do
    expect(question(text: '')).not_to be_valid
    expect(question(slug: '')).not_to be_valid
    expect(question(slug: 'How many?')).not_to be_valid
    expect(question(slug: 'who-holds-it')).not_to be_valid
  end

  it 'shares a slug only with questions for other nations' do
    FactoryBot.create(:topic_question, topic_page: page, slug: 'potholes',
                                       nations: %w[england wales])
    expect(question(slug: 'potholes', nations: ['scotland'])).to be_valid
    expect(question(slug: 'potholes', nations: ['wales'])).not_to be_valid
    expect(question(slug: 'potholes')).not_to be_valid
    expect(FactoryBot.build(:topic_question, slug: 'potholes')).to be_valid
  end

  it 'keeps the slug it was made with, as its address and guides use it' do
    made = FactoryBot.create(:topic_question, topic_page: page,
                                              slug: 'potholes')
    expect(made.update(slug: 'pothole-reports')).to be(false)
    expect(made.reload.slug).to eq('potholes')
    expect(made.update(text: 'How many potholes?')).to be(true)
  end

  it 'keeps its dataset and holder for each nation' do
    expect(question(dataset: { 'wales' => 'road-condition' },
                    holder: { 'scotland' => 'Caledon Roads' })).to be_valid
    expect(question(dataset: 'road-condition')).not_to be_valid
    expect(question(holder: { 'france' => 'Your council' })).not_to be_valid
    expect(question(dataset: { 'wales' => '' })).not_to be_valid
  end

  it 'asks an authority, a tag, a web address or a search on the other site' do
    [{ 'body' => 'Northmoor Council' }, { 'tag' => 'council' },
     { 'url' => 'https://council.example/ask' }, { 'wdtk' => 'council' },
     { 'tag' => 'council', 'wdtk' => 'council' }].each do |ask|
      expect(question(ask: ask)).to be_valid
    end
    [{ 'body' => 'Northmoor Council', 'url' => 'https://council.example' },
     { 'tag' => '' }, { 'url' => 'javascript:alert(1)' },
     { 'url' => 'council.example' }, ['council']].each do |ask|
      expect(question(ask: ask)).not_to be_valid
    end
  end

  it 'links a published answer by its web address' do
    expect(question(published: 'https://statistics.example/roads')).
      to be_valid
    expect(question(published: 'data:text/html,roads')).not_to be_valid
  end

  it 'can’t name a dataset that doesn’t exist' do
    made = question(dataset: { 'wales' => 'road-condition' })
    expect(made.save).to be(false)
    expect(made.errors.full_messages.sole).to include(
      'It can’t be saved:', 'needs the dataset road-condition'
    )
    expect(made).to be_new_record
    FactoryBot.create(:topic_dataset, key: 'road-condition')
    expect(made.save).to be(true)
  end

  it 'stays while a topic guide is for it and no other wording has its slug' do
    england = FactoryBot.create(:topic_question, topic_page: page,
                                                 slug: 'potholes',
                                                 nations: ['england'])
    scotland = FactoryBot.create(:topic_question, topic_page: page,
                                                  slug: 'potholes',
                                                  nations: ['scotland'])
    FactoryBot.create(:topic_guide, dataset_id: nil, topic_slug: page.slug,
                                    question_slug: 'potholes')
    expect(england.destroy).to be_truthy
    expect(scotland.destroy).to be(false)
    expect(scotland.errors.full_messages.sole).
      to include('a topic guide needs the question potholes')
    expect(described_class.exists?(scotland.id)).to be(true)
  end

  it 'takes its turn before its checks, so two admins can’t both pass them' do
    made = question(slug: 'potholes')
    page
    steps = []
    allow(TopicChange).to receive(:take_turn).and_wrap_original do |original|
      steps << :turn
      original.call
    end
    allow(made).to receive(:valid?).and_wrap_original do |original, *args|
      steps << :check
      original.call(*args)
    end
    made.save!
    expect(steps.first(2)).to eq(%i[turn check])
  end
end
