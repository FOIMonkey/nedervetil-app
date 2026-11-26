require 'spec_helper'

RSpec.describe 'Private accounts with public document publications' do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'
  include_context 'with production error pages'

  let(:owner) {
    FactoryBot.create(:user, name: 'Rowan Requester', trusted: true)
  }
  let(:other) { FactoryBot.create(:user) }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:thread) {
    FactoryBot.create(:info_request, user: owner,
                                     title: 'Secretthreadtoken ' \
                                            'never a publication')
  }

  def make_document(request = thread)
    delivered_document(request,
                       'records.txt',
                       'text/plain',
                       "Publicledgerword repairs by ward\nNorth 12\n",
                       ready: false)
  end

  def public_path(document, suffix = '')
    "/documents/#{document.public_id}#{suffix}"
  end

  it 'keeps deliberately published bytes public while all source aliases stay private' do
    document = publish(make_document, by: admin)
    urls = [request_path(thread), request_path(thread, format: :json),
            "/request/#{thread.url_title}/details",
            "/request/#{thread.url_title}/download",
            "/request/#{thread.url_title}/feed",
            "/request/#{thread.url_title}/track",
            "/request_event/#{thread.info_request_events.first.id}",
            "/help/unhappy/#{thread.url_title}"]
    [nil, other].each do |viewer|
      viewer ? sign_in(viewer) : reset!
      urls.each do |url|
        get url
        expect(response.status).to eq(404), url
        expect(response.body).not_to include('Secretthreadtoken')
        expect(response.headers['Location'].to_s).
          not_to include(thread.url_title)
      end
      get public_path(document)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Publicledgerword')
      expect(response.body).
        not_to include(thread.title,
                       thread.url_title,
                       owner.name,
                       'document-manage')
      get public_path(document, '/download')
      expect(response.body).to eq(document.bytes)
    end
  end

  describe 'independent request parameters' do
    let(:readable_request) { FactoryBot.create(:info_request, user: other) }

    before { sign_in(other) }

    ['/help/unhappy/', '/request/'].each do |prefix|
      it "does not authorize #{prefix} with another title parameter" do
        thread.update!(prominence_reason: 'Private reason token')
        get "#{prefix}#{thread.url_title}",
            params: { request_url_title: readable_request.url_title }

        expect(response).to have_http_status(:not_found)
        expect(response.body).
          not_to include(thread.title, 'Private reason token')
      end
    end

    it 'checks the event request even when a title parameter is supplied' do
      event = FactoryBot.create(:edit_event, info_request: thread)
      get "/request_event/#{event.id}",
          params: { url_title: readable_request.url_title }

      expect(response).to have_http_status(:not_found)
      expect(response.headers['Location'].to_s).
        not_to include(thread.url_title)
    end
  end

  it 'denies accounts and JSON to visitors and unrelated Pro accounts' do
    [nil, other].each do |viewer|
      viewer ? sign_in(viewer) : reset!
      ["/user/#{owner.url_name}",
       "/user/#{owner.url_name}.json",
       "/user/#{owner.url_name}/wall",
       "/feed/user/#{owner.url_name}",
       "/user/contact/#{owner.url_name}"].each do |url|
        get url
        expect(response.status).to eq(404), url
        expect(response.body).not_to include(owner.name)
      end
    end
    # There is no JSON page: the account's reader gets 406 as for any
    # format a page doesn't have.
    sign_in(owner)
    get "/user/#{owner.url_name}.json"
    expect(response).to have_http_status(:not_acceptable)
    expect(response.body).not_to include(owner.name)
    expect(response.headers['Cache-Control']).to include('no-store')
  end

  it 'keeps threads and batches private' do
    batch = FactoryBot.create(:info_request_batch, user: owner,
                                                   title: 'Secretbatchtoken')
    expect(Ability.guest.can?(:read, thread.reload)).to eq(false)
    expect(Ability.new(other).can?(:read, thread)).to eq(false)
    get info_request_batch_path(batch)
    expect(response.status).to eq(404)
    expect(response.body).not_to include('Secretbatchtoken')
  end

  it 'separates the public rendition and the private management screen for every viewer' do
    document = make_document
    sign_in(owner)
    get public_path(document)
    expect(response.status).to eq(404)
    get public_path(document, '/manage')
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(thread.title, 'document-manage')
    sign_in(other)
    get public_path(document, '/manage')
    expect(response.status).to eq(404)
    publish(document, by: admin)
    sign_in(admin)
    get public_path(document)
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(thread.title, 'document-manage')
  end

  it 'uses published metadata for pages, search, feeds, authority filters and filenames' do
    document = make_document
    document.update!(title: 'Approvedtitleword',
                     description: 'Approveddescriptionword')
    publish(document, by: admin)
    previous_authority = document.public_body
    other_authority = FactoryBot.create(:public_body)
    thread.update!(title: 'Changedprivatetitle',
                   public_body: other_authority,
                   described_state: 'rejected')
    expect(Disclosures::Search.new(q: 'Approvedtitleword').results).
      to eq([document])
    expect(Disclosures::Search.new(body: previous_authority.url_name).results).
      to eq([document])
    expect(Disclosures::Search.new(body: other_authority.url_name).results).
      to be_empty
    expect(Disclosures::Search.new({}).facets).not_to have_key(:outcome)
    get public_path(document)
    expect(response.body).
      to include('Approvedtitleword', 'Approveddescriptionword')
    expect(response.body).
      not_to include('Changedprivatetitle', other_authority.name)
    get '/'
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Approvedtitleword')
    get public_body_path(previous_authority)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Approvedtitleword')
    expect(response.body).not_to include('Changedprivatetitle')
    get public_path(document, '/download')
    expect(response.headers['Content-Disposition']).
      to include('approvedtitleword.txt')
    get '/documents.json'
    expect(response).
      to have_http_status(:ok),
         "#{response.status} #{response.headers['Location']} " \
         "#{response.body.first(100)}"
    data = JSON.parse(response.body)
    expect(data.first['title']).to eq('Approvedtitleword')
    expect(data.first.keys).
      not_to include('user', 'info_request_id', 'public_body_id')
    get '/documents', params: { feed: '1' }
    expect(response.media_type).to eq('application/atom+xml')
    expect(response.body).to include('Approvedtitleword')
    expect(response.body).not_to include(thread.url_title)
  end

  it 'does not publish request or batch relationships between public documents' do
    batch = FactoryBot.create(:info_request_batch, user: owner,
                                                   title: 'Secretbatchtoken')
    first = publish(make_document, by: admin)
    thread.update!(info_request_batch: batch)
    first.update!(info_request_batch: batch)
    sibling_request = FactoryBot.create(:info_request,
                                        user: owner,
                                        info_request_batch: batch)
    second = publish(make_document(sibling_request), by: admin)
    get '/documents'
    expect(response).to have_http_status(:ok)
    expect(response.body).
      not_to include('Secretbatchtoken', thread.title, 'document-group__title')
    expect(Disclosures::Search.new({}).groups.size).to eq(2)
    get public_path(first)
    expect(response.body).
      not_to include('From the same request',
                     'The same request to other authorities',
                     second.public_id)
  end

  it 'retains live source checks despite snapshot approval, including callback-free changes' do
    document = publish(make_document, by: admin)
    thread.update_columns(prominence: 'requester_only')
    expect(document.reload).to be_listed
    expect(Disclosures::Document.listed).to include(document)
    document.foi_attachment.update_columns(prominence: 'hidden')
    expect(document.reload).not_to be_listed
    expect(Disclosures::Document.listed).not_to include(document)
    get public_path(document)
    expect(response.status).to eq(410)
    get public_path(document, '/download')
    expect(response.status).to eq(404)
  end

  it 'denies signed storage aliases and the retired static cache path' do
    document = publish(make_document, by: admin)
    get rails_blob_path(document.foi_attachment.file, only_path: true)
    expect(response).to have_http_status(:not_found)
    get '/views_cache/a-private-cache-entry'
    expect(response).to have_http_status(:not_found)
    expect(Rails.root.join('public/views_cache')).not_to be_symlink
    get public_path(document, '/download')
    expect(response).to have_http_status(:ok)
  end

  it 'keeps private statistics out of version JSON and public indexing' do
    owner.reindex
    indexed = SearchDocument.find_by(searchable_type: 'User',
                                     searchable_id: owner.id)
    expect(indexed.raw_content).to be_blank
    expect(indexed.raw_admin_content).to include(owner.name)
    get '/version.json'
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).keys).
      to match_array(%w[alaveteli_git_commit alaveteli_version
                        ruby_version public_document_count])
  end

  it 'withdraws a publication when a censor rule affects only approved metadata' do
    document = make_document
    document.update!(title: 'Metadataquillword records')
    publish(document, by: admin)
    # The rule's job finds its words in the public title, which only an
    # admin can change, so the document waits for one.
    perform_enqueued_jobs(only: Disclosures::RuleJob) do
      FactoryBot.create(:info_request_censor_rule, censorable: thread,
                                                   text: 'Metadataquillword',
                                                   replacement: '[removed]')
    end
    expect(document.reload).not_to be_listed
    expect(document.state).to eq('withdrawn')
    get public_path(document, '/download')
    expect(response).to have_http_status(:not_found)
  end
  it 'denies negotiated formats, HEAD and conditional private reads without identifying headers' do
    document = publish(make_document, by: admin)
    [request_path(thread),
     "/user/#{owner.url_name}",
     '/request/absent-private-thread'].each do |path|
      get path, headers: { 'Accept' => 'application/json',
                           'If-None-Match' => '*' }
      expect(response.status).to eq(404)
      expect(response.headers['Cache-Control']).to include('no-store')
      expect(response.headers['Location']).to be_nil
      expect(response.headers['Content-Disposition']).to be_nil
      head path
      expect(response.status).to eq(404)
      expect(response.body).to be_empty
    end
    get public_path(document, '/download'), headers: { 'Range' => 'bytes=0-4' }
    expect(response.status).to eq(200)
    expect(response.body).to eq(document.bytes)
    Disclosures::Publication.new(document, user: admin).withdraw!(
      reason: 'Synthetic withdrawal'
    )
    get public_path(document, '/download'), headers: { 'Range' => 'bytes=0-4',
                                                       'If-None-Match' => '*' }
    expect(response.status).to eq(404)
    expect(response.body).not_to include('Publicledgerword')
  end
end
