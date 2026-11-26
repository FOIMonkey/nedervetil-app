require 'spec_helper'

RSpec.describe 'Request journey navigation', feature: :alaveteli_pro do
  include_context 'with incoming attention off'
  include_context 'with document OCR off'

  let(:owner) do
    FactoryBot.create(:user, name: 'Rowan Requester', trusted: true)
  end
  let(:council) do
    FactoryBot.create(:public_body, name: 'Cowes Example Council',
                                    tag_string: 'local_council county_council')
  end
  let(:other) do
    FactoryBot.create(:public_body, name: 'Shetland Example Council')
  end
  let(:streets) { { 'topic' => 'streets', 'nation' => 'scotland' } }

  def page
    Nokogiri::HTML(response.body)
  end

  def view
    controller.view_context
  end

  def request_form_path(choices = {})
    new_alaveteli_pro_info_request_path(choices)
  end

  def destinations
    journey = view
    %w[request home about topics documents authorities elsewhere].
      index_with { |name| journey.request_journey_destination(name) }
  end

  def expect_inbox_journey(choices)
    carried = choices.empty? ? {} : { request_choice: choices }
    expect(view.request_journey_choices).to eq(choices)
    expect(view.make_request_path).to eq(request_form_path(choices))
    expect(view.make_request_path(other)).to eq(
      request_form_path(choices.merge(public_body: other.url_name))
    )
    expect(destinations).to eq(
      'request' => request_form_path(choices),
      'home' => alaveteli_pro_dashboard_path(carried),
      'about' => help_about_path(carried),
      'topics' => topics_path(carried),
      'documents' => disclosure_documents_path(carried),
      'authorities' => authority_groups_path(carried),
      'elsewhere' => nil
    )
  end

  def expect_classic_journey
    expect(view.make_request_path).to eq(select_authority_path)
    expect(view.make_request_path(other)).
      to eq(new_request_to_body_path(url_name: other.url_name))
    expect(destinations).to eq(
      'request' => select_authority_path,
      'home' => alaveteli_pro_dashboard_path,
      'about' => help_about_path,
      'topics' => topics_path,
      'documents' => disclosure_documents_path,
      'authorities' => authority_groups_path,
      'elsewhere' => nil
    )
  end

  def nav_item(destination)
    html = view.request_journey_nav('Go', destination, id: 'go')
    item = Nokogiri::HTML.fragment(html).children.first
    [item.name, item.to_h, item.text]
  end

  def expect_nav_links(choices)
    carried = choices.empty? ? {} : { request_choice: choices }
    expect(nav_item('request')).
      to eq(['a', { 'id' => 'go', 'href' => request_form_path(choices) }, 'Go'])
    expect(nav_item('topics')).
      to eq(['a', { 'id' => 'go', 'href' => topics_path(carried) }, 'Go'])
  end

  def nav_button(form, name, value)
    ['button',
     { 'name' => name, 'type' => 'submit', 'id' => 'go', 'form' => form,
       'value' => value, 'class' => 'request-nav-action' },
     'Go']
  end

  def expect_nav_buttons(form:, step:)
    expect(nav_item('request')).to eq(nav_button(form, 'journey_step', step))
    expect(nav_item('topics')).
      to eq(nav_button(form, 'journey_destination', 'topics'))
  end

  def menu
    %w[make-request-link dashboard-link].map do |id|
      item = page.at_css("##{id}")
      item.name == 'a' ? item['href'] : item.to_h.slice('form', 'name', 'value')
    end
  end

  def menu_links(choices)
    carried = choices.empty? ? {} : { request_choice: choices }
    [request_form_path(choices), alaveteli_pro_dashboard_path(carried)]
  end

  def menu_buttons(form, step)
    [{ 'form' => form, 'name' => 'journey_step', 'value' => step },
     { 'form' => form, 'name' => 'journey_destination', 'value' => 'home' }]
  end

  def published_document
    request = FactoryBot.create(:info_request, public_body: council,
                                               user: owner)
    message = AttachmentFixtures.deliver(
      request, [['records.txt', 'text/plain', 'Bin collection records']]
    )
    document = Disclosures::Creation.new(
      user: owner,
      attachment: message.get_attachments_for_display.first,
      kind: 'released_records'
    ).create!
    Disclosures::Publication.new(
      document.reload, user: FactoryBot.create(:admin_user)
    ).publish!
    document.reload
  end

  describe 'on a page that adds nothing (About)' do
    before { sign_in(owner) }

    it 'carries no choices when the address has none' do
      get help_about_path
      expect_inbox_journey({})
      expect_nav_links({})
      expect(menu).to eq(menu_links({}))
    end

    it 'builds each path from the choices in the address' do
      get help_about_path, params: {
        request_choice: { subject: 'Bin collections', public_body: 'cowes',
                          journey: { nation: 'wales' } }
      }
      expect(view.make_request_path).to eq(
        '/pro/info_requests/new?journey%5Bnation%5D=wales&public_body=cowes' \
        '&subject=Bin+collections'
      )
      expect(view.request_journey_destination('topics')).to eq(
        '/topics?request_choice%5Bjourney%5D%5Bnation%5D=wales' \
        '&request_choice%5Bpublic_body%5D=cowes' \
        '&request_choice%5Bsubject%5D=Bin+collections'
      )
    end

    it 'tidies each choice in the address' do
      get help_about_path, params: {
        request_choice: {
          subject: "  #{'s' * 250}  ", question: ' How many bins? ',
          public_body: council.url_name, draft_id: '12', from: '34',
          journey: { topic: 'streets', nation: 'wales',
                     holder: 'local_council' }
        }
      }
      choices = {
        subject: 's' * 200, question: 'How many bins?', draft_id: '12',
        from: '34', public_body: council.url_name,
        journey: { 'topic' => 'streets', 'nation' => 'wales',
                   'holder' => 'local_council' }
      }
      expect_inbox_journey(choices)
      expect_nav_links(choices)
      expect(menu).to eq(menu_links(choices))
    end

    it 'drops choices that are malformed' do
      get help_about_path, params: {
        request_choice: {
          subject: '   ', question: '', public_body: 'not a name!',
          draft_id: '12a', from: '-3',
          journey: { topic: 'nope', nation: 'mars', holder: 'nobody' }
        }
      }
      expect_inbox_journey({})
      get help_about_path, params: { request_choice: 'text' }
      expect_inbox_journey({})
    end

    it 'gives the choices to forms and other links in the same order' do
      get help_about_path, params: {
        request_choice: { journey: { nation: 'wales', topic: 'streets' },
                          public_body: 'cowes', from: '34',
                          subject: 'Bin collections' }
      }
      fields = Nokogiri::HTML.fragment(view.request_journey_hidden_fields).
        css('input').map { |input| [input['name'], input['value']] }
      expect(fields).to eq(
        [['request_choice[subject]', 'Bin collections'],
         ['request_choice[from]', '34'],
         ['request_choice[public_body]', 'cowes'],
         ['request_choice[journey][topic]', 'streets'],
         ['request_choice[journey][nation]', 'wales']]
      )
      expect(view.request_journey_link_path('/topics/streets?nation=wales',
                                            public_body: other)).
        to eq(topic_path('streets',
                         nation: 'wales',
                         request_choice: {
                           subject: 'Bin collections', from: '34',
                           public_body: other.url_name,
                           journey: { topic: 'streets', nation: 'wales' }
                         }))
    end
  end

  describe 'signed out' do
    it 'uses the classic request paths and carries nothing between pages' do
      get help_about_path, params: {
        request_choice: { subject: 'Bin collections' }
      }
      expect(view.request_journey_choices).to eq(subject: 'Bin collections')
      expect_classic_journey
      expect(nav_item('request')).
        to eq(['a', { 'id' => 'go', 'href' => select_authority_path }, 'Go'])
      expect(nav_item('topics')).
        to eq(['a', { 'id' => 'go', 'href' => topics_path }, 'Go'])
    end

    it 'does the same on a page that adds a choice' do
      get "/body/#{council.url_name}"
      expect(view.request_journey_choices).
        to eq(public_body: council.url_name)
      expect_classic_journey
    end
  end

  describe 'when a template sets @request_journey_pro, as the themes do' do
    let(:address) { { request_choice: { subject: 'Bin collections' } } }

    def rendered_path(flag)
      view.render(
        inline: "<% @request_journey_pro = #{flag} %><%= make_request_path %>"
      )
    end

    it 'follows the flag rather than the session when signed out' do
      get help_about_path, params: address
      expect(rendered_path(true)).
        to eq(request_form_path(address[:request_choice]))
      expect(rendered_path(false)).to eq(select_authority_path)
    end

    it 'follows the flag rather than the session when signed in' do
      sign_in(owner)
      get help_about_path, params: address
      expect(rendered_path(false)).to eq(select_authority_path)
    end
  end

  describe 'on the inbox list' do
    it 'passes the address choices through, as links' do
      sign_in(owner)
      get alaveteli_pro_info_requests_path, params: {
        request_choice: { subject: 'Bin collections' }
      }
      expect_inbox_journey(subject: 'Bin collections')
      expect_nav_links(subject: 'Bin collections')
      expect(menu).to eq(menu_links(subject: 'Bin collections'))
    end
  end

  describe 'on the request form' do
    let(:address) do
      { subject: 'From the address', question: 'From the address?',
        public_body: other.url_name, draft_id: '7', from: '5',
        journey: { topic: 'streets', holder: 'local_council' } }
    end

    before { sign_in(owner) }

    it 'has nothing to carry at Who, whatever the address says' do
      get new_alaveteli_pro_info_request_path, params: {
        request_choice: address
      }
      expect_inbox_journey({})
      expect_nav_buttons(form: 'authority_form', step: 'who')
      expect(menu).to eq(menu_buttons('authority_form', 'who'))
    end

    it 'carries the authority, subject, question and topic at Subject' do
      get new_alaveteli_pro_info_request_path, params: {
        public_body: council.url_name, subject: 'Bin collections',
        question: 'How many bins were missed?', journey: streets,
        request_choice: address
      }
      expect_inbox_journey(
        subject: 'Bin collections', public_body: council.url_name,
        question: 'How many bins were missed?', journey: streets
      )
      expect_nav_buttons(form: 'subject_form', step: 'subject')
      expect(menu).to eq(menu_buttons('subject_form', 'subject'))
    end

    it 'carries a saved draft and its topic at Write request' do
      draft = FactoryBot.create(:draft_info_request,
                                user: owner, public_body: council,
                                title: 'Bin collections',
                                journey_context: streets)
      get new_alaveteli_pro_info_request_path, params: {
        draft_id: draft.id, request_choice: address
      }
      expect_inbox_journey(subject: 'Bin collections',
                           public_body: council.url_name,
                           draft_id: draft.id, journey: streets)
      expect_nav_buttons(form: 'write_form', step: 'write')
      expect(menu).to eq(menu_buttons('write_form', 'write'))
    end

    it 'carries the request being copied' do
      old = FactoryBot.create(:info_request, user: owner, public_body: council,
                                             title: 'Bin collections 2025')
      get new_alaveteli_pro_info_request_path, params: {
        from: old.id, public_body: council.url_name
      }
      follow_redirect!
      expect_inbox_journey(subject: 'Bin collections 2025',
                           public_body: council.url_name,
                           draft_id: owner.draft_info_requests.last.id,
                           from: old.id)
      expect_nav_buttons(form: 'write_form', step: 'write')
    end

    it 'takes the choices along when the menu leaves the form' do
      get new_alaveteli_pro_info_request_path, params: {
        public_body: council.url_name, subject: 'Bin collections',
        journey: streets, journey_destination: 'documents'
      }
      expect(response).to redirect_to(
        disclosure_documents_path(
          request_choice: { subject: 'Bin collections',
                            public_body: council.url_name, journey: streets }
        )
      )
    end

    it 'gives links, not buttons, at Check and send' do
      draft = FactoryBot.create(:draft_info_request,
                                user: owner, public_body: council,
                                title: 'Bin collections',
                                journey_context: streets)
      get preview_new_alaveteli_pro_info_request_path, params: {
        draft_id: draft.id, request_choice: address
      }
      expect(response).to have_http_status(:ok)
      choices = { subject: 'Bin collections', public_body: council.url_name,
                  draft_id: draft.id, journey: streets }
      expect_inbox_journey(choices)
      expect_nav_links(choices)
      expect(menu).to eq(menu_links(choices))
    end

    it 'gives buttons for the letter form when the letter has errors' do
      draft = FactoryBot.create(:draft_info_request,
                                user: owner, public_body: council,
                                title: 'Bin collections', body: nil)
      get preview_new_alaveteli_pro_info_request_path(draft_id: draft.id)
      expect(response).to have_http_status(:unprocessable_content)
      expect_inbox_journey(subject: 'Bin collections',
                           public_body: council.url_name, draft_id: draft.id)
      expect_nav_buttons(form: 'write_form', step: 'write')
      expect(menu).to eq(menu_buttons('write_form', 'write'))
    end

    it 'gives links when sending is refused' do
      newcomer = FactoryBot.create(:user, confirmed_not_spam: false)
      allow(AlaveteliConfiguration).
        to receive(:block_spam_requests).and_return(true)
      draft = FactoryBot.create(
        :draft_info_request,
        user: newcomer, public_body: council,
        title: '[HD] Watch Jason Bourne Online free MOVIE Full-HD'
      )
      reset!
      sign_in(newcomer)
      post alaveteli_pro_info_requests_path, params: {
        draft_id: draft.id, review_token: RequestJourney::Review.token(draft)
      }
      expect(response).to have_http_status(:unprocessable_content)
      choices = { subject: draft.title, public_body: council.url_name,
                  draft_id: draft.id }
      expect_inbox_journey(choices)
      expect_nav_links(choices)
      expect(menu).to eq(menu_links(choices))
    end

    it 'gives letter-form buttons on the page for an authority that ' \
       'cannot be asked' do
      defunct = FactoryBot.create(:public_body, :defunct)
      get new_alaveteli_pro_info_request_path(public_body: defunct.url_name)
      expect_inbox_journey(public_body: defunct.url_name)
      expect_nav_buttons(form: 'write_form', step: 'write')
      expect(menu).to eq(menu_buttons('write_form', 'write'))
    end
  end

  describe 'on the documents search' do
    let(:address) do
      { subject: 'From the address', question: 'From the address?',
        public_body: other.url_name,
        journey: { nation: 'wales', holder: 'local_council' } }
    end

    before { sign_in(owner) }

    it 'carries the search words, authority, topic and nation' do
      get disclosure_documents_path, params: {
        q: 'Table tennis', body: council.url_name, topic: 'streets',
        group: 'scotland'
      }
      choices = { subject: 'Table tennis', public_body: council.url_name,
                  journey: streets }
      expect_inbox_journey(choices)
      expect_nav_links(choices)
      expect(menu).to eq(menu_links(choices))
    end

    it 'keeps the address choices that the search does not set' do
      get disclosure_documents_path, params: { request_choice: address }
      expect_inbox_journey(
        subject: 'From the address', question: 'From the address?',
        public_body: other.url_name,
        journey: { 'nation' => 'wales', 'holder' => 'local_council' }
      )
      get disclosure_documents_path, params: {
        q: 'Table tennis', body: council.url_name, topic: 'streets',
        request_choice: address
      }
      expect_inbox_journey(
        subject: 'Table tennis', question: 'From the address?',
        public_body: council.url_name,
        journey: { 'topic' => 'streets', 'nation' => 'wales',
                   'holder' => 'local_council' }
      )
    end

    it 'gives the choices to the search form in the same order' do
      get disclosure_documents_path, params: {
        q: 'Table tennis', body: council.url_name,
        request_choice: { question: 'From the address?', from: '5' }
      }
      names = Nokogiri::HTML.fragment(view.request_journey_hidden_fields).
        css('input').map { |input| input['name'] }
      expect(names).to eq(
        %w[request_choice[question] request_choice[from]
           request_choice[subject] request_choice[public_body]]
      )
    end
  end

  describe 'on a document page' do
    it 'carries the document’s authority in place of the address’s' do
      document = published_document
      sign_in(owner)
      get disclosure_document_path(document)
      expect_inbox_journey(public_body: council.url_name)
      expect(menu).to eq(menu_links(public_body: council.url_name))
      get disclosure_document_path(document), params: {
        request_choice: { subject: 'From the address',
                          public_body: other.url_name }
      }
      choices = { subject: 'From the address', public_body: council.url_name }
      expect_inbox_journey(choices)
      expect_nav_links(choices)
    end
  end

  describe 'on the topic pages' do
    before { sign_in(owner) }

    it 'carries the topic and nation' do
      get topic_path('streets', nation: 'scotland')
      expect_inbox_journey(journey: streets)
      expect_nav_links(journey: streets)
      expect(menu).to eq(menu_links(journey: streets))
      get topic_holders_path('streets', nation: 'scotland')
      expect_inbox_journey(journey: streets)
    end

    it 'keeps the address choices, except its topic and nation' do
      get topic_path('streets'), params: {
        request_choice: { subject: 'From the address',
                          journey: { nation: 'wales',
                                     holder: 'local_council' } }
      }
      expect_inbox_journey(
        subject: 'From the address',
        journey: { 'topic' => 'streets', 'nation' => 'england',
                   'holder' => 'local_council' }
      )
    end

    it 'adds nothing on the list of topics' do
      get topics_path, params: {
        nation: 'wales', request_choice: { subject: 'From the address' }
      }
      expect_inbox_journey(subject: 'From the address')
      expect_nav_links(subject: 'From the address')
    end
  end

  describe 'on an authority page' do
    it 'carries the authority in place of the address’s' do
      sign_in(owner)
      get "/body/#{council.url_name}"
      expect_inbox_journey(public_body: council.url_name)
      expect(menu).to eq(menu_links(public_body: council.url_name))
      get "/body/#{council.url_name}", params: {
        request_choice: { subject: 'From the address',
                          public_body: other.url_name }
      }
      choices = { subject: 'From the address', public_body: council.url_name }
      expect_inbox_journey(choices)
      expect_nav_links(choices)
    end
  end
end
