require 'spec_helper'

RSpec.describe Topics::Topic do
  let(:data) do
    { 'title' => 'Roads', 'summary' => 'Road records', 'order' => 1 }
  end

  %w[holders elsewhere].each do |field|
    it "rejects a non-web link in #{field}" do
      data[field] = [{ 'to' => { 'url' => 'javascript:alert(1)' } }]
      expect { described_class.new('roads', data) }.
        to raise_error(ArgumentError, /HTTP or HTTPS/)
    end
  end

  it 'rejects a non-web question link' do
    data['questions'] = [{ 'ask' => { 'url' => 'data:text/html,test' } }]
    expect { described_class.new('roads', data) }.
      to raise_error(ArgumentError, /HTTP or HTTPS/)
  end

  it 'rejects non-web published sources' do
    data['published'] = [{ 'url' => 'javascript:alert(1)' }]
    expect { described_class.new('roads', data) }.
      to raise_error(ArgumentError, /HTTP or HTTPS/)
  end

  it 'accepts web sources and local authority references' do
    data['holders'] = [{ 'to' => { 'tag' => 'council' } }]
    data['questions'] = [{ 'published' => 'https://example.test/records' }]
    expect { described_class.new('roads', data) }.not_to raise_error
  end

  describe 'question slugs' do
    def with_questions(*questions)
      data.merge('questions' => questions)
    end

    it 'rejects a slug that isn’t lower case words and hyphens' do
      data = with_questions({ 'text' => 'Potholes?', 'slug' => 'Pot holes' })
      expect { described_class.new('roads', data) }.
        to raise_error(ArgumentError,
                       "roads: question slug Pot holes isn't allowed")
    end

    it 'rejects a slug kept for the topic’s own pages' do
      data = with_questions({ 'text' => 'Who?', 'slug' => 'who-holds-it' })
      expect { described_class.new('roads', data) }.
        to raise_error(ArgumentError,
                       "roads: question slug who-holds-it isn't allowed")
    end

    it 'rejects two questions with one slug for every nation' do
      data = with_questions({ 'text' => 'Road works' },
                            { 'text' => 'Other', 'slug' => 'road-works' })
      expect { described_class.new('roads', data) }.
        to raise_error(ArgumentError,
                       'roads: two questions use the slug road-works')
    end

    it 'rejects two questions with one slug whose nations overlap' do
      data = with_questions(
        { 'text' => 'Potholes', 'nations' => %w[england wales] },
        { 'text' => 'Potholes', 'nations' => %w[wales] }
      )
      expect { described_class.new('roads', data) }.
        to raise_error(ArgumentError,
                       'roads: two questions use the slug potholes')
    end

    it 'rejects one slug for every nation and for one of them' do
      data = with_questions({ 'text' => 'Potholes' },
                            { 'text' => 'Potholes', 'nations' => %w[wales] })
      expect { described_class.new('roads', data) }.
        to raise_error(ArgumentError,
                       'roads: two questions use the slug potholes')
    end

    it 'accepts one slug worded for different nations' do
      data = with_questions(
        { 'text' => 'Potholes', 'nations' => %w[england wales] },
        { 'text' => 'Potholes', 'nations' => %w[scotland] }
      )
      topic = described_class.new('roads', data)

      expect(topic.questions.map(&:slug)).to eq(%w[potholes potholes])
    end

    it 'reports a slug that isn’t allowed before one used twice' do
      data = with_questions({ 'text' => 'A', 'slug' => 'twice' },
                            { 'text' => 'B', 'slug' => 'twice' },
                            { 'text' => 'C', 'slug' => 'Not_allowed' })
      expect { described_class.new('roads', data) }.
        to raise_error(ArgumentError,
                       "roads: question slug Not_allowed isn't allowed")
    end
  end
end
