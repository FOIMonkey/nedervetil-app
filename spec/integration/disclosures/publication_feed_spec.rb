require 'spec_helper'

RSpec.describe 'Publication cursor feed' do
  include PublicationFeedHelpers
  include_context 'with document OCR off'
  include_context 'with production error pages'

  let(:document) { make_feed_document }

  def walk(cursor = nil)
    rows = []
    10.times do
      get feed_path(cursor)
      rows.concat(assert_feed(response))
      cursor = feed_cursor(response)
      return rows unless cursor
    end
    raise 'Cursor did not terminate'
  end

  it 'traverses tied publication times completely without changing the existing catalogue or Atom URLs' do
    expand_catalogue(document, 45)
    get '/documents.json?page=2'
    previous = JSON.parse(response.body)
    expected = Disclosures::Document.listed.
      order(first_published_at: :desc, public_id: :desc).
      pluck('disclosure_documents.public_id')
    rows = walk
    expect(rows.map { |row| row['id'] }).to eq(expected)
    expect(rows.map { |row| row['id'] }.uniq.size).to eq(46)
    get '/documents.json?page=2'
    expect(JSON.parse(response.body)).to eq(previous)
    get '/documents?feed=1'
    expect(response.media_type).to eq('application/atom+xml')
    get '/documents'
    expect(response.media_type).to eq('text/html')
  end

  it 'refills across unsafe batches and exposes no hidden IDs in cursor payloads' do
    base = expand_catalogue(document, 90)
    FoiAttachment.where(id: (base + 21)..(base + 90)).
      update_all(prominence: 'hidden')
    get feed_path
    rows = assert_feed(response)
    expect(rows.size).to eq(20)
    data = Rails.application.
      message_verifier(Disclosures::PublicationFeed::PURPOSE).
      verified(feed_cursor(response),
               purpose: Disclosures::PublicationFeed::PURPOSE)
    expect(data.keys).to match_array(%w[v upper before])
    expect(data['before']).
      to eq([document.first_published_at.utc.iso8601(6), rows.last['id']])
    expect(walk.map { |row| row['id'] }).
      to eq(Disclosures::Document.listed.
              order(first_published_at: :desc, public_id: :desc).
              pluck('disclosure_documents.public_id'))
  end

  it 'does not advertise additional pages for an entirely unsafe catalogue' do
    base = expand_catalogue(document, 12)
    FoiAttachment.where(
      id: ((base + 1)..(base + 12)).to_a + [document.foi_attachment_id]
    ).update_all(prominence: 'hidden')
    get feed_path
    expect(assert_feed(response)).to eq([])
    expect(response.headers['Link']).to be_nil
  end

  it 'fails closed with bounded work when invalid candidates exhaust the scan budget' do
    base = expand_catalogue(document, 50)
    FoiAttachment.where(
      id: ((base + 1)..(base + 50)).to_a + [document.foi_attachment_id]
    ).update_all(prominence: 'hidden')
    stub_const('Disclosures::PublicationFeed::MAX_CANDIDATES', 16)
    get feed_path
    expect(response.status).to eq(503)
    expect(JSON.parse(response.body)).
      to eq('error' => 'Publication feed temporarily unavailable.')
    expect(response.headers['Link']).to be_nil
    expect(response.headers['Cache-Control']).to eq('private, no-store')
  end

  it 'rechecks after candidate selection and refills when a selected document is withdrawn' do
    expand_catalogue(document, 45)
    document.update_columns(first_published_at: 12.hours.ago.change(usec: 0))
    withdrawn = false
    allow_any_instance_of(Disclosures::PublicationFeed).
      to receive(:select_candidates).and_wrap_original do |select|
        select.call
        unless withdrawn
          withdrawn = true
          Disclosures::Publication.new(document, user: @feed_admin).
            withdraw!(reason: 'Synthetic concurrent withdrawal')
        end
      end
    rows = walk
    expect(rows.size).to eq(45)
    expect(rows.map { |row| row['id'] }).not_to include(document.public_id)
    expect(rows.map { |row| row['id'] }.uniq.size).to eq(45)
  end

  it 'counts fetched look-ahead rows against the budget when a withdrawal forces refilling' do
    expand_catalogue(document, 100)
    document.update_columns(first_published_at: 12.hours.ago.change(usec: 0))
    stub_const('Disclosures::PublicationFeed::MAX_CANDIDATES', 64)
    batches = 0
    allow_any_instance_of(Disclosures::PublicationFeed).
      to receive(:candidate_batch).and_wrap_original do |read|
        batches += 1
        read.call
      end
    allow_any_instance_of(Disclosures::PublicationFeed).
      to receive(:select_candidates).and_wrap_original do |select|
        select.call
        document.update_columns(state: 'withdrawn')
      end
    get feed_path
    expect(response.status).to eq(503)
    expect(response.headers['Link']).to be_nil
    expect(response.body).not_to include(document.public_id)
    expect(batches).to eq(1)
  end

  it 'omits a source restricted after candidate selection, even without a callback' do
    document
    allow_any_instance_of(Disclosures::PublicationFeed).
      to receive(:candidate_batch).and_wrap_original do |read|
        rows = read.call
        FoiAttachment.find(document.foi_attachment_id).
          update_columns(prominence: 'hidden')
        rows
      end
    get feed_path
    expect(assert_feed(response)).to eq([])
  end

  it 'accepts a cursor whose boundary publication has since been withdrawn' do
    expand_catalogue(document, 45)
    get feed_path
    first = assert_feed(response)
    cursor = feed_cursor(response)
    boundary = Disclosures::Document.find_by!(public_id: first.last['id'])
    Disclosures::Publication.new(boundary, user: @feed_admin).
      withdraw!(reason: 'Synthetic withdrawal between pages')
    rest = walk(cursor)
    expect(rest.size).to eq(26)
    expect(rest.map { |row| row['id'] } & first.map { |row| row['id'] }).
      to be_empty
  end

  it 'excludes later publications from an existing traversal while a fresh traversal sees them' do
    base = expand_catalogue(document, 45)
    get feed_path
    first = assert_feed(response)
    cursor = feed_cursor(response)
    future = Disclosures::Document.find(base + 1)
    travel_to(1.minute.from_now) do
      future.update_columns(first_published_at: Time.current)
      rest = walk(cursor)
      expect(rest.map { |row| row['id'] }).not_to include(future.public_id)
      get feed_path
      expect(assert_feed(response).first['id']).to eq(future.public_id)
    end
    expect(first.size).to eq(20)
  end

  it 'rejects tampered, oversized, malformed and expired cursors and unsupported filters' do
    expand_catalogue(document, 22)
    get feed_path
    cursor = feed_cursor(response)
    [cursor + 'x', 'x' * 2_049, ['bad'], { bad: 'value' }].each do |bad|
      get '/documents.json', params: { mode: 'publications', cursor: bad }
      expect(response.status).to eq(400)
      expect(response.headers['Cache-Control']).to eq('private, no-store')
    end
    travel_to(2.days.from_now) do
      get feed_path(cursor)
      expect(response.status).to eq(400)
    end
    %i[q page feed body kind year sector file_type].each do |key|
      get '/documents.json', params: { :mode => 'publications', key => '1' }
      expect(response.status).to eq(400)
    end
  end

  it 'accepts only the correct cursor purpose' do
    expand_catalogue(document, 22)
    verifier = Rails.application.
      message_verifier(Disclosures::PublicationFeed::PURPOSE)
    token = verifier.generate(
      { 'v' => 1,
        'upper' => Time.current.iso8601(6),
        'before' => [document.first_published_at.iso8601(6),
                     document.public_id] },
      purpose: 'another-purpose'
    )
    get feed_path(token)
    expect(response.status).to eq(400)
  end

  it 'supports Accept, HEAD and conditional requests, retaining public bytes and private sources' do
    document
    [nil, FactoryBot.create(:user)].each do |viewer|
      viewer ? sign_in(viewer) : reset!
      get '/documents',
          params: { mode: 'publications' },
          headers: { 'Accept' => 'application/json', 'If-None-Match' => '*' }
      expect(assert_feed(response).first['title']).to eq('Approved ledger')
      expect(response.headers['Set-Cookie']).to be_blank unless viewer
      get "/documents/#{document.public_id}/download"
      expect(response.body).to eq(document.bytes)
      get "/request/#{@feed_source.url_title}.json"
      expect(response.status).to eq(404)
      get "/user/#{@feed_owner.url_name}.json"
      expect(response.status).to eq(404)
    end
    head feed_path
    expect(response.status).to eq(200)
    expect(response.body).to be_empty
    expect(response.headers['Cache-Control']).to eq('private, no-store')
  end
end
