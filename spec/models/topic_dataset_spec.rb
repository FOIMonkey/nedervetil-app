require 'spec_helper'

RSpec.describe TopicDataset do
  it 'needs a kind and a status from the lists' do
    expect(FactoryBot.build(:topic_dataset, kind: 'spreadsheet')).
      not_to be_valid
    expect(FactoryBot.build(:topic_dataset, status: 'rumour')).not_to be_valid
  end

  it 'needs a key no other dataset has, and keeps it' do
    dataset = FactoryBot.create(:topic_dataset, key: 'road-condition')
    expect(FactoryBot.build(:topic_dataset, key: 'road-condition')).
      not_to be_valid
    dataset.key = 'road-quality'
    expect(dataset).not_to be_valid
  end

  it 'opens an area only with {gss} in its address and area codes' do
    area = 'https://statistics.example/road-condition/{gss}'
    expect(FactoryBot.build(:topic_dataset, area_url: area,
                                            area_codes: ['E06'])).to be_valid
    expect(FactoryBot.build(:topic_dataset, area_url: area)).not_to be_valid
    expect(FactoryBot.build(:topic_dataset, area_url: area.sub('{gss}', ''),
                                            area_codes: ['E06'])).
      not_to be_valid
  end

  it 'gives readers the dataset as its file did' do
    FactoryBot.create(:topic_dataset, key: 'road-condition',
                                      table_title: 'Table RDC0120',
                                      coverage: '')
    dataset = described_class.where(key: 'road-condition').datasets.sole
    expect(dataset.id).to eq('road-condition')
    expect(dataset.table).to eq('Table RDC0120')
    expect(dataset.coverage).to eq('')
    expect(dataset.nations).to eq(Topics::Topic::NATIONS.keys)
  end

  it 'stays while a topic guide names it' do
    dataset = FactoryBot.create(:topic_dataset, key: 'road-condition')
    FactoryBot.create(:topic_guide, dataset_id: 'road-condition')
    expect(dataset.destroy).to be(false)
    expect(dataset.errors.full_messages.sole).to eq(
      'It can’t be deleted: a topic guide needs the dataset road-condition'
    )
    expect(described_class.exists?(dataset.id)).to be(true)
  end

  it 'stays while a question uses it, saying where' do
    dataset = FactoryBot.create(:topic_dataset, key: 'road-condition')
    FactoryBot.create(:topic_question, text: 'How many potholes?',
                                       dataset: { 'wales' => 'road-condition' })
    expect(dataset.destroy).to be(false)
    expect(dataset.errors.full_messages.sole).
      to include('“How many potholes?”', 'Wales) needs the dataset')
  end

  it 'keeps covering the nations its questions use it in' do
    dataset = FactoryBot.create(:topic_dataset, key: 'road-condition',
                                                nations: %w[england wales])
    FactoryBot.create(:topic_question, text: 'How many potholes?',
                                       dataset: { 'wales' => 'road-condition' })
    expect(dataset.update(nations: ['wales'])).to be(true)
    expect(dataset.update(nations: ['england'])).to be(false)
    expect(dataset.errors.full_messages.sole).
      to include('needs the dataset road-condition, covering Wales')
    expect(dataset.reload.nations).to eq(['wales'])
  end
end
