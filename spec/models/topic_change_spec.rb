require 'spec_helper'

RSpec.describe TopicChange do
  let(:admin) { FactoryBot.create(:admin_user) }

  it 'records a create with the fields it set, made by no one' do
    page = FactoryBot.create(:topic_page, slug: 'roads')
    change = described_class.where(record: page).sole
    expect(change).to have_attributes(record: page, action: 'create',
                                      user: nil)
    expect(change.changeset).to eq('slug' => [nil, 'roads'],
                                   'title' => [nil, 'Roads'],
                                   'summary' => [nil, 'Road records'],
                                   'position' => [nil, 1])
  end

  it 'records an update with only the fields changed, and who changed them' do
    question = FactoryBot.create(:topic_question, keywords: ['pothole'])
    Current.set(user: admin) do
      question.update!(text: 'How many potholes?',
                       keywords: %w[pothole crater])
    end
    change = described_class.last
    expect(change).to have_attributes(record: question, action: 'update',
                                      user: admin)
    expect(change.changeset).to eq(
      'text' => ['How many potholes were reported?', 'How many potholes?'],
      'keywords' => [['pothole'], %w[pothole crater]]
    )
  end

  it 'records nothing for a save that changes nothing, or that fails' do
    dataset = FactoryBot.create(:topic_dataset)
    expect { dataset.save! }.not_to change(described_class, :count)
    expect { dataset.update(kind: 'rumour') }.
      not_to change(described_class, :count)
  end

  it 'records a destroy of a page and each of its rows' do
    page = FactoryBot.create(:topic_page)
    holder = FactoryBot.create(:topic_holder, topic_page: page,
                                              who: 'Your council')
    FactoryBot.create(:topic_route, topic_page: page)
    expect { page.destroy! }.to change(described_class, :count).by(3)
    expect(described_class.find_by(record: holder, action: 'destroy').
           changeset).to include('who' => ['Your council', nil])
  end

  it 'is undone with the write it records' do
    expect do
      TopicPage.transaction do
        FactoryBot.create(:topic_page)
        raise ActiveRecord::Rollback
      end
    end.not_to change(described_class, :count)
  end

  it 'keeps the history as written' do
    page = FactoryBot.create(:topic_page)
    change = described_class.find_by!(record: page)
    expect { change.update!(action: 'destroy') }.
      to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  describe 'with writes committed from two connections' do
    self.use_transactional_tests = false

    let!(:datasets) { TopicDataset.order(:id).first(2) }
    let!(:titles) { datasets.map(&:title) }
    let!(:version) { described_class.maximum(:id) }
    let(:commit) { Queue.new }

    after do
      commit << true
      @threads&.each { |thread| thread.join(10) || thread.kill }
      datasets.zip(titles) { |dataset, title| dataset.reload.update!(title:) }
      described_class.where(id: (version + 1)..).delete_all
    end

    def in_thread(&block)
      Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }
    end

    def waiting_on_a_lock?
      ActiveRecord::Base.connection.select_value(<<~SQL).positive?
        SELECT count(*) FROM pg_stat_activity
        WHERE datname = current_database() AND wait_event_type = 'Lock'
      SQL
    end

    it 'holds a later write until the earlier commits, so the newest id moves with each commit' do
      earlier, later = datasets
      opened = Queue.new
      @threads = [in_thread do
        TopicDataset.transaction do
          earlier.update!(title: 'Earlier')
          opened << true
          commit.pop
        end
      end]
      opened.pop
      @threads << in_thread { later.update!(title: 'Later') }
      deadline = 10.seconds.from_now
      sleep 0.05 until waiting_on_a_lock? || !@threads.last.alive? ||
                       Time.current > deadline

      expect(@threads.last).to be_alive
      expect(described_class.maximum(:id)).to eq(version)
      commit << true
      @threads.each { |thread| thread.join(10) }
      ids = [earlier, later].map do |dataset|
        described_class.where(record: dataset).maximum(:id)
      end
      expect(ids).to eq(ids.sort)
      expect(described_class.maximum(:id)).to eq(ids.last)
    end
  end
end
