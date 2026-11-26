require 'spec_helper'

RSpec.describe Topics::Guide do
  let(:council) { { 'tag' => 'local_council' } }
  let(:data) do
    { 'title' => 'T', 'summary' => 'S', 'order' => 1,
      'holders' => [
        { 'what' => 'Bins', 'key' => 'bins', 'who' => 'District',
          'to' => council },
        { 'what' => 'Roads', 'key' => 'roads', 'who' => 'County',
          'to' => council },
        { 'what' => 'Trains', 'who' => 'Rail', 'to' => { 'body' => 'Rail' } },
        { 'what' => 'Lochs', 'who' => 'Scots', 'nations' => ['scotland'] }
      ],
      'questions' => [
        { 'text' => 'Potholes?', 'ask' => council, 'holder' => 'roads' },
        { 'text' => 'CCTV?', 'ask' => council },
        { 'text' => 'Late trains?', 'ask' => { 'body' => 'Rail' },
          'published' => 'https://example.com/a', 'partial' => true },
        { 'text' => 'Fares?', 'published' => 'https://example.com/b' }
      ],
      'elsewhere' => [
        { 'what' => 'Your own file', 'route' => 'Ask for your records' },
        { 'what' => 'Report a pothole', 'route' => 'Report it' },
        { 'what' => 'Water companies', 'route' => 'On the other site',
          'to' => { 'wdtk' => 'water' } }
      ],
      'refused' => ['Addresses.', 'Names.'] }
  end
  let(:topic) { Topics::Topic.new('t', data) }
  let(:guide) { described_class.new(topic, 'england') }

  def entry(text)
    guide.entries.find { |row| row.question.text == text }
  end

  it 'says what state each answer is in' do
    expect(guide.entries.map(&:state)).
      to eq(%i[ask ask partial published])
  end

  it 'finds who to ask from the question, or where only one holder fits' do
    expect(entry('Potholes?').holder.who).to eq('County')
    expect(entry('Late trains?').holder.who).to eq('Rail')
  end

  it 'names nobody when several holders fit and the question does not say' do
    expect(entry('CCTV?').holder).to be_nil
  end

  it 'limits holders to the nation' do
    expect(guide.holders.map(&:who)).not_to include('Scots')
  end

  it 'sorts the other routes by what they are for' do
    expect(guide.own.map(&:what)).to eq(['Your own file'])
    expect(guide.instead.map(&:what)).to eq(['Report a pothole'])
    expect(guide.elsewhere.map(&:what)).to eq(['Water companies'])
  end

  it 'leaves out refusals already shown against a question' do
    data['questions'].first['warning'] = 'Addresses.'
    expect(guide.warnings).to eq(['Names.'])
  end

  it 'puts what can be looked up, even in part, before what can only be asked' do
    expect(guide.look_up.map { _1.question.text }).
      to eq(['Late trains?', 'Fares?'])
    expect(guide.ask_for.map { _1.question.text }).to eq(['Potholes?', 'CCTV?'])
  end

  it 'finds a question by the last part of its address' do
    expect(guide.entry('late-trains').question.text).to eq('Late trains?')
    expect(guide.entry('nothing')).to be_nil
  end

  it 'lists published sources that no question links to' do
    data['published'] = [
      { 'label' => 'Fares', 'url' => 'https://example.com/b' },
      { 'label' => 'Other', 'url' => 'https://example.com/c' }
    ]
    expect(guide.published.map(&:label)).to eq(['Other'])
  end

  it 'names the holder per nation, and asks that body' do
    data['holders'].last['to'] = { 'body' => 'Scots' }
    data['questions'].first['holder'] = { 'scotland' => 'Scots' }
    scots = described_class.new(topic, 'scotland').entries.first
    expect(scots.holder.who).to eq('Scots')
    expect(scots.ask_to).to eq('body' => 'Scots')
    expect(guide.entries.first.ask_to).to eq(council)
  end
end
