require 'spec_helper'

RSpec.describe TopicHolder do
  it 'says what is held and who holds it' do
    expect(FactoryBot.build(:topic_holder, what: '')).not_to be_valid
    expect(FactoryBot.build(:topic_holder, who: '')).not_to be_valid
  end

  it 'labels and tags each group' do
    expect(FactoryBot.build(:topic_holder, groups: [
                              { 'label' => 'Councils', 'tag' => 'council' }
                            ])).to be_valid
    expect(FactoryBot.build(:topic_holder, groups: [{ 'tag' => 'council' }])).
      not_to be_valid
  end

  it 'is for the nations it lists' do
    expect(FactoryBot.build(:topic_holder, nations: ['wales'])).to be_valid
    expect(FactoryBot.build(:topic_holder, nations: ['France'])).
      not_to be_valid
  end

  it 'takes a key once and keeps it, as holds_not: tags use it' do
    holder = FactoryBot.create(:topic_holder)
    expect(holder.update(key: 'potholes')).to be(true)
    expect(holder.update(key: 'roads')).to be(false)
    expect(holder.update(key: nil)).to be(false)
    expect(holder.reload.key).to eq('potholes')
  end

  describe 'deleting' do
    let(:page) { FactoryBot.create(:topic_page) }
    let!(:holder) do
      FactoryBot.create(:topic_holder, topic_page: page, key: 'roads',
                                       who: 'Your council',
                                       nations: %w[england wales])
    end

    def question(holder_map)
      FactoryBot.create(:topic_question, topic_page: page, holder: holder_map,
                                         text: 'How many potholes?')
    end

    it 'stays while a question names it by key, saying which' do
      question('england' => 'roads')
      expect(holder.destroy).to be(false)
      expect(holder.errors.full_messages.sole).to include('How many potholes?')
      expect(described_class.exists?(holder.id)).to be(true)
    end

    it 'stays while a question names it by who' do
      question('wales' => 'Your council')
      expect(holder.destroy).to be(false)
    end

    it 'goes when the questions name it only in nations it isn’t for' do
      # Content from before the check, naming it where it isn't for.
      question({}).update_columns(holder: { 'scotland' => 'roads' })
      expect(holder.destroy).to be_truthy
    end

    it 'goes when another holder of that name is for the nation' do
      question('england' => 'roads')
      FactoryBot.create(:topic_holder, topic_page: page, key: 'roads',
                                       position: 1)
      expect(holder.destroy).to be_truthy
    end

    it 'goes when only another topic’s question names it' do
      other = FactoryBot.create(:topic_page)
      FactoryBot.create(:topic_holder, topic_page: other, key: 'roads')
      FactoryBot.create(:topic_question, topic_page: other,
                                         holder: { 'england' => 'roads' })
      expect(holder.destroy).to be_truthy
    end
  end

  describe 'renaming' do
    let(:page) { FactoryBot.create(:topic_page) }
    let!(:holder) do
      FactoryBot.create(:topic_holder, topic_page: page, who: 'Your council',
                                       nations: %w[england wales])
    end

    it 'takes the questions that name it by who, in its nations, with it' do
      FactoryBot.create(:topic_holder, topic_page: page, who: 'Your council',
                                       nations: ['scotland'], position: 1)
      question = FactoryBot.create(
        :topic_question, topic_page: page,
                         holder: { 'england' => 'Your council',
                                   'scotland' => 'Your council' }
      )
      expect(holder.update(who: 'Your county council')).to be(true)
      expect(question.reload.holder).to eq(
        'england' => 'Your county council', 'scotland' => 'Your council'
      )
      expect(TopicChange.where(record: question).last.changeset['holder']).
        to be_present
    end

    it 'leaves a question that found another holder of that name first' do
      first = FactoryBot.create(:topic_holder, topic_page: page,
                                               who: 'Your council',
                                               nations: ['england'],
                                               position: -1)
      question = FactoryBot.create(:topic_question,
                                   topic_page: page,
                                   holder: { 'england' => 'Your council' })
      expect(holder.update(who: 'Your county council')).to be(true)
      expect(question.reload.holder).to eq('england' => 'Your council')
      expect(first.update(who: 'Your district council')).to be(true)
      expect(question.reload.holder).
        to eq('england' => 'Your district council')
    end
  end

  it 'links to its authority like a question asks one' do
    expect(FactoryBot.build(:topic_holder, to: { 'url' => 'ftp://x.example' })).
      not_to be_valid
  end
end
