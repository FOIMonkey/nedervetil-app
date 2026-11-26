require 'spec_helper'

RSpec.describe Disclosures::TopicMatch do
  include PublicationFeedHelpers
  include_context 'with document OCR off'

  let(:row) { Struct.new(:slug, :title, :search) }
  let(:document) { make_feed_document }

  def topics_with(*words)
    allow(Topics::Topic).to receive(:all).
      and_return(words.map { |word| row.new(word, word.capitalize, word) })
  end

  def matches
    described_class.pluck(:topic, :document_id)
  end

  def counts(params = {})
    Disclosures::Search.new(params).facet(:topic).to_h { |slug, _, count| [slug, count] }
  end

  it 'records a published document’s matches on its details and pages' do
    topics_with('ledger', 'ward', 'quokkaword')
    doc = document
    expect(matches).
      to contain_exactly(['ledger', doc.id], ['ward', doc.id])
    expect(counts).to eq('ledger' => 1, 'ward' => 1)
  end

  it 'updates matches when details change' do
    topics_with('ledger', 'quokkaword')
    document.update!(title: 'Approved quokkaword')
    described_class.record(document)
    expect(matches).to include(['quokkaword', document.id])
    expect(counts).to eq('ledger' => 1, 'quokkaword' => 1)
  end

  it 'reads visibility live: a withdrawal drops the count and the filter at once' do
    topics_with('ledger')
    document
    expect(counts).to eq('ledger' => 1)
    expect(Disclosures::Search.new(topic: 'ledger').total).to eq(1)

    document.update_columns(state: 'withdrawn')
    expect(counts).to eq({})
    expect(Disclosures::Search.new(topic: 'ledger').total).to eq(0)
  end

  it 'ignores drafts on a rebuild' do
    topics_with('quokkaword')
    document.update_columns(state: 'draft', title: 'Private quokkaword')
    described_class.rebuild
    expect(matches).to be_empty
  end

  it 'takes on changed words, and forgets removed topics, when rebuilt' do
    topics_with('ledger')
    doc = document
    topics_with('ward')
    expect(counts).to eq({})

    described_class.rebuild
    expect(matches).to eq([['ward', doc.id]])
    expect(counts).to eq('ward' => 1)
  end

  it 'matches a topic saved with search words, as its page is saved' do
    doc = document
    perform_enqueued_jobs do
      FactoryBot.create(:topic_page, slug: 'ledgers', search: 'ledger')
    end
    expect(matches).to include(['ledgers', doc.id])
    expect(counts).to include('ledgers' => 1)
  end

  it 'goes when its document goes' do
    topics_with('ledger')
    doc = document
    doc.destroy!
    expect(matches).to be_empty
  end
end
