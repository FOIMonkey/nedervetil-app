require 'spec_helper'

RSpec.describe Topics::Content do
  let(:streets) { TopicPage.find_by!(slug: 'streets') }
  let(:dataset) { TopicDataset.find_by!(key: 'glenmoor-parking-fines') }

  def topic_statements
    sql = []
    callback = ->(*, payload) do
      sql << payload[:sql] if payload[:sql].include?('"topic_') &&
                              !payload[:cached]
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      yield
    end
    sql
  end

  # What a reader sees of one topic and one dataset.
  def seen(content)
    [content.topics.find { |topic| topic.slug == 'streets' }.summary,
     content.datasets.fetch('glenmoor-parking-fines').title]
  end

  def next_request
    Current.reset
  end

  it 'asks only for the version on a request after the first, while nothing changes' do
    Topics::Topic.all
    next_request
    statements = topic_statements do
      Topics::Topic.all.flat_map(&:questions).
        each { |question| question.dataset_for('scotland') }
      Topics::Topic.find('streets')
      Topics::Dataset.index
    end
    expect(statements).
      to contain_exactly(a_string_matching(/MAX\("topic_changes"\."id"\)/))
  end

  it 'gives the next request a write, in this process and in another' do
    other_process = Topics::Content::Cache.new
    other_process.fetch(described_class.version)
    Topics::Topic.all
    streets.update!(summary: 'Bins and potholes')
    dataset.update!(title: 'Parking fines')
    next_request

    expect(Topics::Topic.find('streets').summary).to eq('Bins and potholes')
    expect(Topics::Dataset.find('glenmoor-parking-fines').title).
      to eq('Parking fines')
    expect(seen(other_process.fetch(described_class.version))).
      to eq(['Bins and potholes', 'Parking fines'])
  end

  it 'goes back to the content before a write that rolls back' do
    summary = Topics::Topic.find('streets').summary
    TopicPage.transaction(requires_new: true) do
      streets.update!(summary: 'Rolled back')
      expect(Topics::Topic.find('streets').summary).to eq('Rolled back')
      raise ActiveRecord::Rollback
    end
    expect(Topics::Topic.find('streets').summary).to eq(summary)
  end

  it 'builds again when a write lands while it builds, so no copy mixes two versions' do
    allow(TopicDataset).to receive(:datasets).and_wrap_original do |original|
      streets.update!(summary: 'Landed') unless streets.summary == 'Landed'
      original.call
    end
    content = Topics::Content::Cache.new.fetch(described_class.version)
    expect(content.version).to eq(described_class.version)
    expect(seen(content).first).to eq('Landed')
  end

  it 'gives a request during a rebuild the whole old copy or the whole new one' do
    cache = Topics::Content::Cache.new
    before = described_class.version
    old = seen(cache.fetch(before))
    streets.update!(summary: 'Bins and potholes')
    dataset.update!(title: 'Parking fines')
    after = described_class.version
    building = Queue.new
    built = Queue.new
    allow(TopicDataset).to receive(:datasets).and_wrap_original do |original|
      building << true
      built.pop
      original.call
    end

    rebuild = Thread.new { seen(cache.fetch(after)) }
    building.pop
    early, late = [before, after].map do |version|
      Thread.new { seen(cache.fetch(version)) }
    end
    deadline = 10.seconds.from_now
    sleep 0.01 until [early, late].all? { |reader| reader.status != 'run' } ||
                     Time.current > deadline
    3.times { built << true }

    new = ['Bins and potholes', 'Parking fines']
    expect([old, new]).to include(early.value)
    expect([rebuild.value, late.value]).to eq([new, new])
    expect(building).to be_empty
  ensure
    3.times { built << true } if built
    [rebuild, early, late].compact.each { |thread| thread.join(10) }
  end

  it 'is frozen all the way down, as a process’s threads share it' do
    expect(Ractor.shareable?(Topics::Topic.all)).to be(true)
    expect(Ractor.shareable?(Topics::Dataset.index)).to be(true)
    expect { Topics::Topic.find('streets').questions.first.text << '?' }.
      to raise_error(FrozenError)
  end
end
