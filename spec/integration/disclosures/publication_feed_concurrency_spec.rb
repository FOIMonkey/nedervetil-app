require 'spec_helper'
require 'timeout'

RSpec.describe 'Publication feed readers and withdrawal on separate connections' do
  self.use_transactional_tests = false
  include PublicationFeedHelpers
  include_context 'with document OCR off'
  include_context 'with production error pages'

  it 'removes a committed withdrawal from four requests already holding candidate IDs' do
    document = make_feed_document
    get feed_path
    expect(assert_feed(response).first['id']).to eq(document.public_id)
    ready = Queue.new
    proceed = Queue.new
    readers = []
    allow_any_instance_of(Disclosures::PublicationFeed).
      to receive(:candidate_batch).and_wrap_original do |read|
        rows = read.call
        if Thread.current[:feed_reader_waiting]
          Thread.current[:feed_reader_waiting] = false
          ready << ActiveRecord::Base.connection.
                     select_value('SELECT pg_backend_pid()')
          Timeout.timeout(10) { proceed.pop }
        end
        rows
      end
    readers = Array.new(4) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Thread.current[:feed_reader_waiting] = true
          session = ActionDispatch::Integration::Session.new(Rails.application)
          session.get(feed_path)
          result = [session.response.status,
                    session.response.headers['Cache-Control'],
                    JSON.parse(session.response.body)]
          session.get(feed_path)
          [result,
           [session.response.status, session.response.headers['Cache-Control'],
            JSON.parse(session.response.body)]]
        end
      end
    end
    backends = Timeout.timeout(10) { Array.new(4) { ready.pop } }
    writer = ActiveRecord::Base.connection.
      select_value('SELECT pg_backend_pid()')
    expect((backends + [writer]).uniq.size).to eq(5)
    Disclosures::Publication.new(document.reload, user: @feed_admin).
      withdraw!(reason: 'Synthetic editor withdrawal while four readers wait')
    4.times { proceed << true }
    results = Timeout.timeout(15) { readers.flat_map(&:value) }
    expect(results).to all(eq([200, 'private, no-store', []]))
    get "/documents/#{document.public_id}/download"
    expect(response.status).to eq(404)
    get "/request/#{@feed_source.url_title}.json"
    expect(response.status).to eq(404)
  ensure
    4.times { proceed << true } if proceed
    readers&.each { |thread| thread.join(15) }
    document&.destroy!
    @feed_source&.destroy!
    @feed_authority&.destroy!
    @feed_owner&.destroy!
    @feed_admin&.destroy!
  end
end
