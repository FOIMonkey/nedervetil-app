require 'spec_helper'

RSpec.describe 'A connected request journey', feature: :alaveteli_pro do
  include ActiveJob::TestHelper
  include_context 'with incoming attention off'
  include_context 'with document OCR off'

  let(:owner) {
    FactoryBot.create(:user, name: 'Rowan Requester', trusted: true)
  }
  let(:council) {
    FactoryBot.create(:public_body, name: 'Cowes Example Council',
                                    tag_string: 'local_council county_council')
  }
  let(:other) {
    FactoryBot.create(:public_body,
                      name: 'Shetland Example Council',
                      tag_string: 'local_council ' \
                                                'scottish_council scotland')
  }
  let(:admin) { FactoryBot.create(:admin_user) }
  def page
    Nokogiri::HTML(response.body)
  end

  def published(text, body: council, title: 'Sports funding')
    request = FactoryBot.create(:info_request, public_body: body,
                                               user: owner,
                                               title: 'Synthetic sports record')
    message = AttachmentFixtures.deliver(request,
                                         [['records.txt', 'text/plain', text]])
    document = Disclosures::Creation.new(
      user: owner,
      attachment: message.get_attachments_for_display.first,
      kind: 'released_records'
    ).create!
    document.reload.update!(title: title)
    Disclosures::Publication.new(document, user: admin).publish!
    document.reload
  end

  def reads
    sql = []
    callback = ->(*args) {
      event = args.last
      sql << event[:sql] unless event[:name] == 'SCHEMA' || event[:cached]
    }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { yield }
    sql.select { |statement| statement.match?(/\A\s*(SELECT|WITH)/i) }
  end

  it 'ignores malformed or unknown journey choices' do
    expect(RequestJourney::Context.new('bad').values).to eq({})
    expect(RequestJourney::Context.new(['bad']).values).to eq({})
    expect(RequestJourney::Context.new(topic: 'unknown',
                                       nation: 'unknown',
                                       holder: 'unknown').values).to eq({})
  end

  it 'starts with Who and opens an authority entry at Subject without searching publications' do
    sign_in(owner)
    expect(RequestJourney::Suggestions).not_to receive(:new)
    get new_alaveteli_pro_info_request_path
    expect(page.at_css('#content h1').text).to eq('Who holds it?')
    get new_alaveteli_pro_info_request_path(public_body: council.url_name)
    expect(page.at_css('#content h1').text).to eq('Request subject')
    expect(page.at_css('#subject')['value']).to eq('')
    expect(page.at_css('.request-to button')['value']).to eq('who')
  end

  it 'carries a topic question, nation and holder into the picker and filters before limiting' do
    council
    other
    sign_in(owner)
    question = Topics::Topic.find('streets').questions.
               find { |each| each.text.include?('parking') }
    get topic_question_path('streets', question.slug, nation: 'scotland')
    link = page.at_css('.topic-question__main a.triage-btn[data-ask]')
    expect(link).to be_present
    uri = URI.parse(link['href'])
    query = Rack::Utils.parse_nested_query(uri.query)
    expect(query.dig('journey', 'nation')).to eq('scotland')
    expect(query['subject']).to include('parking')
    expect(query['question']).to include('parking')
    get uri.path, params: query.merge('query' => 'Example')
    names = page.css('.authority-results__name').map(&:text)
    expect(names).to include(other.name)
    expect(names).not_to include(council.name)
    get page.at_css('.authority-results__name')['href']
    expect(page.at_css('#content h1').text).to eq('Request subject')
    expect(page.at_css('#subject')['value']).to eq(query['subject'])
  end

  it 'carries search words and a selected authority into Subject' do
    sign_in(owner)
    get '/documents', params: { q: 'Table tennis funding',
                                body: council.url_name }
    get page.at_css('.search-request a')['href']
    expect(page.at_css('#content h1').text).to eq('Request subject')
    expect(page.at_css('#subject')['value']).to eq('Table tennis funding')
    expect(page.at_css('.request-to').text).to include(council.name)
  end

  it 'requires a subject, checks short subjects, and uses the chosen nation for curated sources' do
    sign_in(owner)
    get new_alaveteli_pro_info_request_path(public_body: council.url_name,
                                            subject: '',
                                            check: 1)
    expect(page.at_css('#subject-error').text).to include('Subject missing')
    get new_alaveteli_pro_info_request_path(public_body: other.url_name,
                                            subject: 'Parking tickets',
                                            check: 1)
    expect(page.at_css('.request-suggestions')).to be_present
    url = Topics::Dataset.find('glenmoor-parking-fines').url
    expect(page.css('.request-suggestions a').map { |link| link['href'] }).
      to include(url)
  end

  it 'finds a published page and external title for this authority and excludes the other authority' do
    own = published('Cowes table tennis grants 2025: £1200. A < B & the club ' \
                    'received funding.')
    elsewhere = published('Cowes table tennis grants 2025: £9999.', body: other)
    AuthorityGroups::ExternalRelease.create!(public_body: council,
                                             title: 'Table tennis grants 2025',
                                             url: 'https://example.invalid/cowes',
                                             released_on: Date.new(2026, 1, 1))
    AuthorityGroups::ExternalRelease.create!(public_body: other,
                                             title: 'Table tennis grants 2025',
                                             url: 'https://example.invalid/shetland',
                                             released_on: Date.new(2026, 1, 1))
    sign_in(owner)
    get new_alaveteli_pro_info_request_path(public_body: council.url_name,
                                            subject: 'Table tennis grants',
                                            check: 1)
    links = page.css('.request-suggestions a').map { |link| link['href'] }
    expect(links.any? { |url| url.start_with?(disclosure_document_path(own)) }).
      to be true
    local = links.find { |url| url.start_with?(disclosure_document_path(own)) }
    local_choices = Rack::Utils.parse_nested_query(URI.parse(local).query).fetch('request_choice')
    expect(local_choices['subject']).to eq('Table tennis grants')
    expect(URI.parse(local).fragment).to eq('page-1')
    get local
    view = controller.view_context
    view.request_journey_pro?
    expect(reads { 3.times { view.make_request_path } }).to be_empty
    get view.make_request_path
    expect(page.at_css('#subject')['value']).to eq('Table tennis grants')
    get new_alaveteli_pro_info_request_path(public_body: council.url_name,
                                            subject: 'Table tennis grants',
                                            check: 1)
    expect(links).to include('https://example.invalid/cowes')
    expect(links.join).not_to include(elsewhere.public_id, '/shetland')
    expect(page.at_css('.request-suggestions__excerpt').text).
      to include('£1200')
    expect(response.body).not_to include('£9999', 'answers your question')
  end

  it 'shows the excerpt the catalogue shows: the best page, with table cells apart' do
    document = published('Annual report. Table tennis grants are listed later.')
    document.pages.create!(
      number: 2, label: 'Page 2', kind: 'text',
      text: "Table tennis grants\nClub\tGrant\n" \
            "Cowes table tennis club\t1200\nTable tennis grants paid in 2025"
    )
    hit = RequestJourney::Suggestions.new(council, 'Table tennis grants').
          documents.first.hit
    catalogue = Disclosures::Search.new(q: 'Table tennis grants').
                hits[document.id].first
    expect([hit.number, catalogue.number]).to eq([2, 2])
    expect(hit.snippet).to include('Club · <mark>Grant</mark>')
    expect(catalogue.snippet).to include('Club · <mark>Grant</mark>')
  end

  it 'does not search private letters, drafts, or withdrawn documents' do
    private_request = FactoryBot.create(:info_request, user: owner,
                                                       public_body: council,
                                                       title: 'Privateonlyword')
    private_request.outgoing_messages.first.
      update_columns(body: 'Privateonlyword')
    document = published('Publishedword sports funding')
    draft_message = AttachmentFixtures.deliver(
      private_request, [['draft.txt', 'text/plain', 'Draftonlyword']]
    )
    Disclosures::Creation.new(
      user: owner,
      attachment: draft_message.get_attachments_for_display.first,
      kind: 'released_records'
    ).create!
    expect(RequestJourney::Suggestions.new(council,
                                           'Privateonlyword').documents).
      to be_empty
    expect(RequestJourney::Suggestions.new(council, 'Draftonlyword').documents).
      to be_empty
    Disclosures::Publication.new(document, user: owner).withdraw!(
      reason: 'Synthetic test'
    )
    expect(RequestJourney::Suggestions.new(council, 'Publishedword').documents).
      to be_empty
  end

  it 'keeps wording and topic choices when changing steps, changing authority and reopening a draft' do
    sign_in(owner)
    context = { topic: 'streets', nation: 'england', holder: 'local_council' }
    post alaveteli_pro_info_requests_path, params: {
      info_request: { title: 'Table tennis spending',
                      public_body_id: council.id },
      outgoing_message: { letter: 'Please provide the grants paid in 2025.' },
      journey: context,
      journey_step: 'who'
    }
    expect(response).
      to redirect_to(new_alaveteli_pro_info_request_path(
                       draft_id: owner.draft_info_requests.last.id,
                       step: 'who'
                     ))
    follow_redirect!
    draft = owner.draft_info_requests.last
    expect(draft.journey_context).
      to include('topic' => 'streets', 'nation' => 'england')
    expect(page.at_css('input[name="subject"]')['value']).
      to eq('Table tennis spending')
    get new_alaveteli_pro_info_request_path(draft_id: draft.id,
                                            public_body: other.url_name,
                                            step: 'subject')
    expect(page.at_css('#subject')['value']).to eq('Table tennis spending')
    get new_alaveteli_pro_info_request_path(draft_id: draft.id,
                                            public_body: other.url_name,
                                            subject: 'Sports grants',
                                            step: 'write')
    expect(page.at_css('textarea[name="outgoing_message[letter]"]').text).
      to include('Please provide the grants paid in 2025.')
    post alaveteli_pro_info_requests_path, params: {
      draft_id: draft.id, info_request: { title: 'Sports grants',
                                          public_body_id: other.id },
      outgoing_message: { letter: 'Please provide the grants paid in 2025.' },
      journey: context,
      save_draft: 1
    }
    follow_redirect!
    expect(page.at_css('#info_request_title')['value']).to eq('Sports grants')
    expect(page.at_css('.request-sheet__to').text).to include(other.name)
    expect(draft.reload.body).to start_with("Dear #{other.name},")
    expect(draft.journey_context).to include('topic' => 'streets')
  end

  it 'does not allow another account to open a saved journey or copy a private request' do
    draft = owner.draft_info_requests.create!(title: 'Private draft',
                                              public_body: council,
                                              body: 'Private wording')
    old = FactoryBot.create(:info_request, user: owner, public_body: council)
    sign_in(FactoryBot.create(:user))
    get new_alaveteli_pro_info_request_path(draft_id: draft.id)
    expect(response).to have_http_status(:not_found)
    get new_alaveteli_pro_info_request_path(from: old.id,
                                            public_body: council.url_name)
    expect(response.body).not_to include('Private wording')
  end

  it 'sends the edited subject and letter through the normal private request path' do
    sign_in(owner)
    post alaveteli_pro_info_requests_path, params: {
      info_request: { title: 'Cowes sports grants 2025',
                      public_body_id: council.id },
      outgoing_message: { letter: 'Please provide the grants paid to table ' \
                                  'tennis clubs during 2025.' },
      review: 1
    }
    expect(response).to have_http_status(:redirect)
    follow_redirect!
    expect(page.at_css('#content h1').text).to eq('Check and send')
    form = page.at_css('#send_form')
    post form['action'],
         params: { draft_id: form.at_css('[name="draft_id"]')['value'],
                   review_token: form.at_css('[name="review_token"]')['value'],
                   send: 1 }
    sent = owner.info_requests.last
    expect(sent.title).to eq('Cowes sports grants 2025')
    expect(sent.prominence).to eq('requester_only')
    expect(sent.outgoing_messages.first.body).
      to include('table tennis clubs during 2025')
    expect(owner.draft_info_requests).to be_empty
  end

  it 'caps publication reads and avoids counts, facets and per-page queries as documents grow' do
    document = published('Table tennis funding')
    council.name
    # Topic content is read once a request or job, however many documents.
    Topics::Topic.all
    baseline = reads do
      found = RequestJourney::Suggestions.new(council, 'Table tennis')
      [found.questions, found.documents, found.releases]
    end
    100.times do |number|
      document.pages.create!(number: number + 2,
                             label: "Page #{number + 2}",
                             kind: 'text',
                             text: 'Table tennis funding')
    end
    larger = reads do
      found = RequestJourney::Suggestions.new(council, 'Table tennis')
      expect(found.documents.length).to eq(1)
      [found.questions, found.documents, found.releases]
    end
    expect(larger.size).to eq(baseline.size)
    expect(larger.size).to be <= 6
    expect(larger.join).
      not_to match(/count\(\*\)|GROUP BY|active_storage|thumbnail/i)
    puts "Request suggestions: #{larger.size} SELECTs at 1 and 101 pages; no " \
         "counts/facets/thumbnails"
  end
end
