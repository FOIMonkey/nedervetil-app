require 'spec_helper'

RSpec.describe 'Catalogue query efficiency' do
  include PublicationFeedHelpers
  include_context 'with document OCR off'
  include_context 'with production error pages'

  let!(:document) { make_feed_document }
  let(:row) { Struct.new(:slug, :title, :search) }
  let(:topics) do
    [row.new('ledger', 'Ledger', 'ledger'),
     row.new('repairs', 'Repairs', 'repairs OR ward'),
     row.new('missing', 'Missing', 'quokkaword'),
     row.new('phrase', 'Phrase', '"ledger repairs" -snow')]
  end

  def topic_counts(params = {})
    Disclosures::TopicMatch.rebuild
    Disclosures::Search.new(params).facet(:topic).
      to_h { |slug, _, count| [slug, count] }
  end

  def selects
    queries = []
    listener = ->(*, payload) do
      unless payload[:cached] || %w[SCHEMA TRANSACTION].include?(payload[:name])
        queries << payload[:sql]
      end
    end
    ActiveRecord::Base.uncached do
      ActiveSupport::Notifications.subscribed(listener, 'sql.active_record') do
        yield
      end
    end
    queries.grep(/\A\s*(SELECT|WITH)\b/i)
  end

  def spread_over_bodies(base, count)
    bodies = Array.new(count) do |index|
      FactoryBot.create(:public_body, name: "Synthetic body #{count}-#{index}")
    end
    Disclosures::Document.where('id > ?', base).
      order(:id).each_with_index do |record, index|
        record.update_columns(public_body_id: bodies[index % count].id)
      end
    bodies
  end

  it 'batches overlapping metadata/page matches, counting a document once across matching pages' do
    allow(Topics::Topic).to receive(:all).and_return(topics)
    page = document.pages.first
    document.pages.create!(number: 2,
                           label: 'Page 2',
                           kind: page.kind,
                           text: page.text,
                           text_source: page.text_source)
    expect(topic_counts).to eq('ledger' => 1, 'repairs' => 1, 'phrase' => 1)
    expect(topic_counts(body: @feed_authority.url_name)).
      to eq('ledger' => 1, 'repairs' => 1, 'phrase' => 1)
    expect(selects { topic_counts }.size).to eq(1)
  end

  it 'drops only the topic facet’s own filter and retains every other filter' do
    allow(Topics::Topic).to receive(:all).and_return(topics)
    expect(topic_counts(topic: 'missing')).
      to eq('ledger' => 1, 'repairs' => 1, 'phrase' => 1)
    expect(topic_counts(q: 'quokkaword')).to eq({})
    expect(topic_counts(kind: 'decision_letter')).to eq({})
    expect(topic_counts(file_type: 'pdf')).to eq({})
    expect(topic_counts(year: '2024')).to eq({})
    expect(topic_counts(body: @feed_authority.url_name)).
      to eq('ledger' => 1, 'repairs' => 1, 'phrase' => 1)
    expect(topic_counts(body: 'no-such-authority')).to eq({})
  end

  it 'keeps unpublished drafts and callback-skipping restrictions out of topic counts' do
    allow(Topics::Topic).to receive(:all).and_return(topics)
    message = AttachmentFixtures.deliver(
      @feed_source, [['draft.txt', 'text/plain', "quokkaword\n"]]
    )
    draft = Disclosures::Creation.new(
      user: @feed_owner,
      attachment: message.get_attachments_for_display.first,
      kind: 'released_records'
    ).create!
    draft.update!(title: 'Private quokkaword',
                  description: 'Private quokkaword')
    expect(topic_counts).to eq('ledger' => 1, 'repairs' => 1, 'phrase' => 1)
    FoiAttachment.where(id: document.foi_attachment_id).
      update_all(prominence: 'hidden')
    expect(topic_counts).to eq({})
    expect(Disclosures::Search.new({}).total).to eq(0)
  end

  describe 'scoring pages' do
    # Details never match and the oldest document's page matches best, so only
    # scoring its page puts it first. Newest is base + 4.
    def found
      search = Disclosures::Search.new(q: 'quokkaword')
      [search.total, search.results.map(&:id)]
    end

    let!(:base) do
      expand_catalogue(document, 4).tap do |first|
        Disclosures::Page.where('document_id > ?', first).
          update_all(text: 'quokkaword and much else besides, and more')
        Disclosures::Page.where(document_id: first + 1).
          update_all(text: 'quokkaword quokkaword quokkaword')
      end
    end

    it 'gives the best page first when the matches are within the cap' do
      expect(found).to eq([4, [base + 1, base + 4, base + 3, base + 2]])
    end

    it 'scores pages for the newest within the cap, and still lists every match once' do
      stub_const('Disclosures::Search::PAGE_SCORED', 2)
      expect(found).to eq([4, [base + 4, base + 3, base + 2, base + 1]])
    end

    it 'lets strong details into the cap ahead of newer documents' do
      stub_const('Disclosures::Search::PAGE_SCORED', 1)
      Disclosures::Document.where(id: base + 2).
        update_all(title: 'quokkaword')
      expect(found.last.first).to eq(base + 2)
    end

    it 'keeps the order across pages' do
      stub_const('Disclosures::Search::PAGE_SCORED', 2)
      stub_const('Disclosures::Search::PER_PAGE', 3)
      pages = [1, 2].flat_map do |number|
        Disclosures::Search.new(q: 'quokkaword', page: number).results.map(&:id)
      end
      expect(pages).to eq([base + 4, base + 3, base + 2, base + 1])
    end
  end

  it 'reuses matching totals without replacing a selected type’s narrower count' do
    search = Disclosures::Search.new({})
    expect(search.facet(:kind)).
      to eq([['released_records', 'Released records', 1]])
    expect(selects { expect(search.total).to eq(1) }).to be_empty
    filtered = Disclosures::Search.new(kind: 'decision_letter')
    expect(filtered.facet(:kind).sum { |_, _, count| count }).to eq(1)
    expect(filtered.total).to eq(0)
    document.update_columns(state: 'withdrawn')
    expect(Disclosures::Search.new({}).total).to eq(0)
  end

  it 'batches authority translations without changing labels or counts' do
    bodies = spread_over_bodies(expand_catalogue(document, 24), 8)
    search = Disclosures::Search.new({})
    values = nil
    expect(selects { values = search.facet(:body) }.size).to eq(3)
    expect(values.sum { |_, _, count| count }).to eq(25)
    bodies.each do |body|
      expect(values.to_h { |slug, _, count| [slug, count] }[body.url_name]).
        to eq(3)
    end
  end

  it 'never matches a draft, withdrawn or hidden-file document, filtered or not' do
    base = expand_catalogue(document, 3)
    marked = ->(id, text) do
      Disclosures::Document.find(id).pages.update_all(text: text)
    end
    marked.call(base + 1, 'Quokkalive tables')
    marked.call(base + 2, 'Quokkawithdrawn tables')
    marked.call(base + 3, 'Quokkahidden tables')
    Disclosures::Document.where(id: base + 2).update_all(state: 'withdrawn')
    Disclosures::Document.find(base + 3).foi_attachment.
      update_columns(prominence: 'hidden')
    document.pages.update_all(text: 'Quokkacurrent tables')
    expect(Disclosures::Document.listed.count).to eq(2)

    body = @feed_authority.url_name
    found = ->(word) do
      allow(Topics::Topic).
        to receive(:all).and_return([row.new('marker', 'Marker', word)])
      Disclosures::TopicMatch.rebuild
      ids = [Disclosures::Search.new(q: word),
             Disclosures::Search.new(q: word, body: body)].map do |search|
        [search.total, search.results.map(&:id)]
      end
      counts = [
        Disclosures::Search.new({}), Disclosures::Search.new(body: body)
      ].map { |search| search.facet(:topic) }
      get '/documents.json', params: { q: word }
      [ids, counts, JSON.parse(response.body).map { |record| record['id'] }]
    end
    marker = [['marker', 'Marker', 1]]
    expect(found.call('quokkalive')).
      to eq([[[1, [base + 1]], [1, [base + 1]]],
             [marker, marker],
             [Disclosures::Document.find(base + 1).public_id]])
    expect(found.call('quokkacurrent')).
      to eq([[[1, [document.id]], [1, [document.id]]],
             [marker, marker],
             [document.public_id]])
    %w[quokkawithdrawn quokkahidden].each do |word|
      expect(found.call(word)).to eq([[[0, []], [0, []]], [[], []], []]), word
    end
  end

  it 'keeps the catalogue to the same statements however many authorities have documents' do
    # Core creates its internal admin authority on first use; creating it here
    # keeps that out of the counts.
    PublicBody.internal_admin_body
    pages = -> do
      get '/documents'
      browse = selects { get '/documents' }
      expect(response).to have_http_status(:ok)
      body = selects do
        get '/documents', params: { body: @feed_authority.url_name }
      end
      expect(response).to have_http_status(:ok)
      search = selects { get '/documents', params: { q: 'ledger' } }
      expect(response).to have_http_status(:ok)
      [browse.size, body.size, search.size]
    end
    base = expand_catalogue(document, 60)
    spread_over_bodies(base, 15)
    few = pages.call
    spread_over_bodies(base, 45)
    expect(pages.call).to eq(few)
    expect(few.max).to be <= 40
  end

  it 'retains fresh public counts, no-store responses and private source denials' do
    %w[/documents /documents.json /documents.atom].each do |path|
      get path
      expect(response).to have_http_status(:ok)
      expect(response.headers['Cache-Control']).to eq('private, no-store')
      expect(response.headers['Set-Cookie']).to be_blank
      expect(response.body).
        not_to include('Private source marker', 'Private requester marker')
    end
    document.update_columns(state: 'withdrawn')
    get '/documents.json'
    expect(JSON.parse(response.body)).to eq([])
    expect(Disclosures::Search.new({}).facet(:kind)).to eq([])
    get "/request/#{@feed_source.url_title}.json"
    expect(response).to have_http_status(:not_found)
  end
end
