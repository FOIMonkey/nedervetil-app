require 'spec_helper'

RSpec.describe 'Reviewing a finished request', feature: :alaveteli_pro do
  include_context 'with incoming attention off'
  include_context 'with production error pages'

  let(:owner) {
    FactoryBot.create(:user, name: 'Rowan Requester', trusted: true)
  }
  let(:body) {
    FactoryBot.create(:public_body,
                      name: 'Cowes Example Council',
                      tag_string: 'local_council county_council')
  }
  let(:context) {
    { topic: 'streets', nation: 'england', holder: 'local_council' }
  }
  def page
    Nokogiri::HTML(response.body)
  end

  before do
    sign_in(owner)
  end

  def write(letter, **options)
    post alaveteli_pro_info_requests_path, params: {
      info_request: { title: 'Table tennis grants', public_body_id: body.id },
      outgoing_message: { letter: letter }, journey: context, **options
    }
  end

  def send_params
    page.css('#send_form input[type="hidden"]').
      to_h { |node| [node['name'], node['value']] }.merge('send' => '1')
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

  it 'checks the finished letter on review, escapes it, and never searches documents there or when sending' do
    get new_alaveteli_pro_info_request_path(public_body: body.url_name,
                                            subject: 'Table tennis',
                                            step: 'write')
    follow_redirect!
    expect(response.headers['Cache-Control']).to include('private', 'no-store')
    expect(response.headers['Vary']).to include('Cookie')
    expect(page.at_css('#submit_button')).to be_nil
    expect(response.body).
      not_to include('Late?', 'You can remind them in one click.')
    expect(page.at_css('.request-check__nudge')).to be_nil
    expect(page.at_css('#write_form button[hidden]')['name']).to eq('review')
    expect(RequestJourney::Suggestions).not_to receive(:new)
    letter = "Please provide the grants register for 2025.\nPlease provide " \
             "all emails about it.\n<script>invented</script>"
    queries = reads do
      write(letter, review: 1)
      expect(owner.info_requests).to be_empty
      follow_redirect!
    end
    expect(page.at_css('#content h1').text).to eq('Check and send')
    expect(response.headers['Cache-Control']).to include('private', 'no-store')
    expect(response.body).
      not_to include('Late?', 'You can remind them in one click.')
    expect(page.at_css('.request-sheet__review').text).to include(letter)
    expect(page.at_css('.request-sheet__review script')).to be_nil
    expect(page.at_css('.request-check__nudge').text).
      to include('Name the records')
    expect(page.css('.request-check__nudge').size).to eq(1)
    expect(page.at_css('#send_form textarea, #send_form input[name*="body"]')).
      to be_nil
    params = send_params
    queries += reads { post alaveteli_pro_info_requests_path, params: params }
    expect(queries.grep(/disclosure_|authority_external_releases/i)).to be_empty
    expect(owner.info_requests.reload.last.outgoing_messages.first.body).
      to include(letter)
    expect(owner.info_requests.reload.last.prominence).to eq('requester_only')
  end

  it 'returns to writing with the saved words and refreshes advice after editing' do
    write('Please provide all correspondence about grants.', review: 1)
    follow_redirect!
    expect(page.at_css('.request-check__nudge').text).
      to include('Name the records')
    get page.at_css('.request-flow__main > p a')['href']
    expect(page.at_css('#outgoing_message_letter').text).
      to include('all correspondence')
    draft = owner.draft_info_requests.last
    write('Please provide a copy of my file.', draft_id: draft.id, review: 1)
    follow_redirect!
    expect(page.at_css('.request-check__nudge').text).to include('About you?')
    expect(response.body).not_to include('all correspondence')
    expect(draft.reload.journey_context).to include('topic' => 'streets')
  end

  it 'requires a review and refuses a send from an older reviewed version' do
    write('Please provide the 2025 grants register.', send: 1)
    expect(owner.info_requests).to be_empty
    follow_redirect!
    old = send_params
    draft = owner.draft_info_requests.last
    draft.update!(body: 'Please provide the changed synthetic record.')
    post alaveteli_pro_info_requests_path, params: old
    expect(owner.info_requests).to be_empty
    expect(response).
      to redirect_to(
        preview_new_alaveteli_pro_info_request_path(draft_id: draft.id)
      )
    follow_redirect!
    expect(page.at_css('.request-sheet__review').text).
      to include('changed synthetic record')
    post alaveteli_pro_info_requests_path,
         params: send_params.merge('review_token' => 'invalid')
    expect(owner.info_requests).to be_empty
  end

  it 'makes the results action carry the search words, authority and nation without lookups' do
    heading = Category.create!(title: 'Place',
                               description: '',
                               parent_ids: [PublicBody.category_root.id])
    Category.create!(title: 'England',
                     description: '',
                     category_tag: 'england',
                     parent_ids: [heading.id])
    body.update!(tag_string: 'local_council county_council england')
    get '/documents', params: { q: 'Table tennis',
                                body: body.url_name,
                                group: 'england',
                                topic: 'streets' }
    expect(response.headers['Cache-Control']).to include('private', 'no-store')
    expect(page.at_css('#content h1').text).to eq('Search results')
    path = page.at_css('.search-request a')['href']
    view = controller.view_context
    view.make_request_path
    expect(reads { 3.times { view.make_request_path } }).to be_empty
    get path
    expect(page.at_css('#subject')['value']).to eq('Table tennis')
    expect(page.at_css('.request-to').text).to include(body.name)
    expect(page.at_css('[name="journey[nation]"]')['value']).to eq('england')
  end

  it 'makes Check publications run its check after saving the current letter' do
    write('Please provide the grants paid in 2025.',
          journey_step: 'publications')
    draft = owner.draft_info_requests.last
    expect(response).
      to redirect_to(new_alaveteli_pro_info_request_path(draft_id: draft.id,
                                                         step: 'subject',
                                                         check: 1))
    expect(RequestJourney::Suggestions).
      to receive(:new).with(body, 'Table tennis grants').once.and_call_original
    follow_redirect!
    expect(draft.reload.body).to include('grants paid in 2025')
  end

  it 'keeps a saved request through secondary topic links and a document search' do
    write('Please provide the edited grants register.',
          journey_destination: 'topics')
    follow_redirect!
    get page.at_css('.topics__other a')['href']
    choices = page.css('input[name^="request_choice"]').to_h { |field|
      [field['name'], field['value']]
    }
    expect(choices['request_choice[draft_id]']).
      to eq(owner.draft_info_requests.last.id.to_s)
    query = Rack::Utils.parse_nested_query(choices.to_query).merge(
      'q' => 'Table tennis'
    )
    get '/documents', params: query
    get page.at_css('.search-request a')['href']
    expect(page.at_css('#outgoing_message_letter').text).
      to include('edited grants register')
    expect(page.at_css('#info_request_title')['value']).to eq('Table tennis')
    expect(page.at_css('.request-sheet__to').text).to include(body.name)
  end

  it 'starts a separate letter for an explicit topic question and preserves the earlier saved draft' do
    write('Please provide the sports grants register.',
          journey_destination: 'topics')
    draft = owner.draft_info_requests.last
    follow_redirect!
    question = Topics::Topic.find('streets').questions.
               find { |each| each.text.include?('CCTV') }
    get topic_question_path('streets', question.slug)
    link = page.at_css('.topic-question__main a.triage-btn[data-ask]')
    choice = Rack::Utils.parse_nested_query(URI.parse(link['href']).query)
    expect(choice).not_to have_key('draft_id')
    get URI.parse(link['href']).path,
        params: choice.merge('public_body' => body.url_name, 'step' => 'write')
    follow_redirect!
    expect(page.at_css('#outgoing_message_letter').text).to include('CCTV')
    expect(page.at_css('#outgoing_message_letter').text).
      not_to include('sports grants')
    expect(draft.reload.body).to include('sports grants')
  end

  it 'rejects another account’s draft even with a valid review token' do
    other = FactoryBot.create(:user)
    secret = %w[Private wording unique].join(' ')
    draft = other.draft_info_requests.create!(title: 'Private',
                                              public_body: body,
                                              body: secret)
    token = RequestJourney::Review.token(draft)
    get preview_new_alaveteli_pro_info_request_path(draft_id: draft.id)
    expect(response).to have_http_status(:not_found)
    expect(response.headers['Cache-Control']).to include('private', 'no-store')
    post alaveteli_pro_info_requests_path, params: { draft_id: draft.id,
                                                     review_token: token }
    expect(response).to have_http_status(:not_found)
    expect(response.body).not_to include(secret)
  end
end
