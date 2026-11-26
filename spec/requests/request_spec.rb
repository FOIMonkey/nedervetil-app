require 'spec_helper'

RSpec.describe 'Request pages', type: :request do
  # Assert sign-in succeeded so a later refusal isn't a false pass.
  def sign_in_as(user)
    sign_in(user)
    expect(response).to have_http_status(:see_other)
  end

  def page
    Nokogiri::HTML(response.body)
  end

  def show(info_request, params = {})
    get show_request_path(info_request.url_title), params: params
  end

  def expect_requester_page_for(info_request)
    expect(response).to have_http_status(:ok)
    expect(page.at_css('.requester-page')).to be_present
    expect(page.at_css('h1.request-band__title').text).
      to eq(info_request.title)
  end

  def expect_admin_page_for(info_request)
    expect(response).to have_http_status(:ok)
    expect(page.at_css('.requester-page')).to be_nil
    expect(page.at_css('.request-header h1').text).to eq(info_request.title)
    expect(page.at_css('#after_actions')).to be_present
  end

  def status_form
    page.at_css('form#describe_form_1')
  end

  def status_form_open?
    page.at_css('details#describe_state_form_1')&.key?('open')
  end

  def offered_transitions(form)
    groups = { 'This request is still in progress:' => :pending,
               'This particular request is finished:' => :complete,
               'Other:' => :other }
    offered = { pending: {}, complete: {}, other: {} }
    form.css("input[name='classification[described_state]']").each do |input|
      group = groups.fetch(input.xpath('preceding::h3[1]').text.strip)
      label = form.at_css("label[for='#{input['id']}'] span").inner_html
      offered[group][input['value']] = label
    end
    offered
  end

  def update_status_links
    page.css('#after_actions a').
      select { |link| link.text == 'Update the status of this request' }.
      map { |link| link['href'] }.uniq
  end

  def expect_no_update_status_menu
    links = page.css('a').map { |link| link.text.strip }
    expect(links).not_to include('Update the status of this request')
  end

  let(:admin) { FactoryBot.create(:admin_user) }

  def show_to_admin(info_request, params = {})
    reset!
    sign_in_as admin
    show(info_request, params)
  end

  describe 'when showing one request' do
    let(:fancy_dog) { info_requests(:fancy_dog_request) }
    let(:naughty_chicken) { info_requests(:naughty_chicken_request) }

    it 'shows the requester their request' do
      sign_in_as users(:bob_smith_user)
      show(fancy_dog)
      expect_requester_page_for(fancy_dog)
    end

    it 'returns a 404 for GET requests to a malformed request URL' do
      get show_request_path('228%85')
      expect(response).to have_http_status(:not_found)
    end

    describe 'livery used', feature: :alaveteli_pro do
      let(:pro_user) { FactoryBot.create(:pro_user) }

      before { sign_in_as pro_user }

      context "when showing pros a someone else's request" do
        it 'is not found' do
          show(fancy_dog)
          expect(response).to have_http_status(:not_found)
        end
      end
    end

    context 'when the request is private to its requester' do
      let(:private_request) do
        FactoryBot.create(:info_request, :requester_only)
      end

      it 'is not found' do
        show(private_request)
        expect(response).to have_http_status(:not_found)
      end

      it "doesn't even redirect from a numeric id" do
        get show_request_path(private_request.id)
        expect(response).to have_http_status(:not_found)
      end
    end

    describe 'when handling an update_status parameter' do
      it 'opens the status form if the parameter is present' do
        sign_in_as users(:bob_smith_user)
        show(fancy_dog, update_status: 1)
        expect(status_form).to be_present
        expect(status_form_open?).to be(true)
      end

      it 'leaves the status form closed if the parameter is not present' do
        sign_in_as users(:bob_smith_user)
        show(fancy_dog)
        expect(status_form).to be_present
        expect(status_form_open?).to be(false)
      end

      it 'does not show the request if not logged in' do
        show(fancy_dog, update_status: 1)
        expect(response).to have_http_status(:not_found)
      end

      it 'works if logged in as the requester' do
        sign_in_as users(:bob_smith_user)
        show(fancy_dog, update_status: 1)
        expect_requester_page_for(fancy_dog)
      end

      it 'does not work if logged in as not the requester' do
        sign_in_as users(:silly_name_user)
        show(fancy_dog, update_status: 1)
        expect(response).to have_http_status(:not_found)
      end

      it 'works if logged in as an admin user' do
        sign_in_as users(:admin_user)
        show(fancy_dog, update_status: 1)
        expect_admin_page_for(fancy_dog)
      end
    end

    # Requesters get one status form; admins get separate top and bottom forms.
    describe 'the top status form' do
      context 'when update_status is not asked for' do
        it 'is not shown' do
          expect(naughty_chicken.awaiting_description).to be false
          sign_in_as users(:bob_smith_user)
          show(naughty_chicken)
          expect(status_form).to be_nil

          show_to_admin(naughty_chicken)
          expect_admin_page_for(naughty_chicken)
          expect(page.at_css('div#describe_state_form_1')).to be_nil
        end

        context 'but the request is awaiting_description' do
          it 'is shown' do
            sign_in_as users(:bob_smith_user)
            show(fancy_dog)
            expect(status_form).to be_present

            show_to_admin(fancy_dog)
            expect(page.at_css('div#describe_state_form_1 form')).to be_present
          end
        end
      end

      context 'when update_status is asked for' do
        it 'is shown' do
          expect(naughty_chicken.awaiting_description).to be false
          sign_in_as users(:bob_smith_user)
          show(naughty_chicken, update_status: '1')
          expect(status_form).to be_present
          expect(status_form_open?).to be(true)

          show_to_admin(naughty_chicken, update_status: '1')
          expect(page.at_css('div#describe_state_form_1 form')).to be_present
        end

        context 'and the request is awaiting_description' do
          it 'is shown' do
            sign_in_as users(:bob_smith_user)
            show(fancy_dog, update_status: '1')
            expect(status_form).to be_present
            expect(status_form_open?).to be(true)

            show_to_admin(fancy_dog, update_status: '1')
            expect(page.at_css('div#describe_state_form_1 form')).to be_present
          end
        end
      end

      context 'when there are no valid state transitions' do
        it 'is not shown' do
          info_request = FactoryBot.create(:info_request)
          info_request.set_described_state('not_foi')
          sign_in_as info_request.user
          show(info_request, update_status: '1')
          expect_requester_page_for(info_request)
          expect(status_form).to be_nil

          show_to_admin(info_request, update_status: '1')
          expect_admin_page_for(info_request)
          expect(page.at_css('div#describe_state_form_1')).to be_nil
        end
      end
    end

    describe 'the bottom status form' do
      context 'when the request is awaiting_description' do
        it 'is shown' do
          sign_in_as users(:bob_smith_user)
          show(fancy_dog)
          expect(status_form).to be_present

          show_to_admin(fancy_dog)
          expect(page.at_css('div#describe_state_form_2 form')).to be_present
        end
      end

      context 'when the request is not awaiting_description' do
        it 'is not shown' do
          expect(naughty_chicken.awaiting_description).to be false
          sign_in_as users(:bob_smith_user)
          show(naughty_chicken)
          expect(status_form).to be_nil

          show_to_admin(naughty_chicken)
          expect_admin_page_for(naughty_chicken)
          expect(page.at_css('div#describe_state_form_2')).to be_nil
        end
      end

      context 'when there are no valid state transitions' do
        it 'is not shown' do
          info_request = FactoryBot.create(:info_request)
          info_request.set_described_state('not_foi')
          sign_in_as info_request.user
          show(info_request)
          expect_requester_page_for(info_request)
          expect(status_form).to be_nil

          show_to_admin(info_request)
          expect_admin_page_for(info_request)
          expect(page.at_css('div#describe_state_form_2')).to be_nil
        end
      end
    end

    it 'offers the states the request can move to' do
      info_request = FactoryBot.create(:info_request_with_incoming)
      expected_transitions = {
        pending: {
          'waiting_response' => "I'm still <strong>waiting</strong> for my " \
            'information <small>(maybe you got an acknowledgement)</small>',
          'waiting_clarification' => "I've been asked to <strong>clarify" \
            '</strong> my request',
          'gone_postal' => 'They are going to reply <strong>by postal ' \
            'mail</strong>',
          'under_appeal' => "I've <strong>appealed</strong> to the " \
            'regulator or a tribunal'
        },
        complete: {
          'partially_successful' => "I've received <strong>some of the " \
            'information</strong>',
          'successful' => "I've received <strong>all the information</strong>",
          'rejected' => "I've received <strong>no information</strong>"
        },
        other: {
          'error_message' => "I've received an <strong>error message</strong>"
        }
      }
      sign_in_as info_request.user
      show(info_request)
      expect(offered_transitions(status_form)).to eq(expected_transitions)
    end

    describe 'showing update status actions' do
      def show_to_requester_then_admin(info_request)
        sign_in_as info_request.user
        show(info_request)
        expect_requester_page_for(info_request)
        expect_no_update_status_menu

        show_to_admin(info_request)
        expect_admin_page_for(info_request)
      end

      context 'when the request is old and unclassified' do
        let(:info_request) { FactoryBot.create(:old_unclassified_request) }

        before do
          expect(info_request.is_old_unclassified?).to be true
          show_to_requester_then_admin(info_request)
        end

        it 'does not link to asking for the update status form' do
          expect(update_status_links).
            not_to include(request_path(info_request, update_status: 1))
        end

        it 'links to the status form on the page' do
          expect(update_status_links).to eq(['#describe_state_form_1'])
        end
      end

      context 'when the request is not old and unclassified' do
        let(:info_request) { FactoryBot.create(:info_request) }

        before do
          show_to_requester_then_admin(info_request)
        end

        it 'links to asking for the update status form' do
          expect(update_status_links).
            to eq([request_path(info_request, update_status: 1)])
        end

        it 'does not link to the status form on the page' do
          expect(update_status_links).not_to include('#describe_state_form_1')
        end
      end

      context 'when there are no state_transitions' do
        let(:info_request) { FactoryBot.create(:info_request) }

        before do
          info_request.set_described_state('not_foi')
        end

        it 'hides all status update options' do
          show_to_requester_then_admin(info_request)
          expect(update_status_links).to be_empty
        end
      end
    end
  end

  describe 'when handling prominence' do
    let(:info_request) do
      FactoryBot.create(:info_request_with_pdf_attachment,
                        prominence: prominence)
    end

    context 'when the request is hidden' do
      let(:prominence) { 'hidden' }

      it 'does not show the request if not logged in' do
        show(info_request)
        expect(response).to have_http_status(:not_found)
      end

      it 'does not show the request even if logged in as their owner' do
        sign_in_as info_request.user
        show(info_request)
        expect(response).to have_http_status(:not_found)
      end

      it 'does not show the request if requested using json' do
        sign_in_as info_request.user
        get show_request_path(info_request.url_title, format: 'json')
        expect(response).to have_http_status(:not_found)
      end

      it 'shows the request if logged in as super user' do
        sign_in_as admin
        show(info_request)
        expect_admin_page_for(info_request)
      end
    end

    context 'when the request is requester_only' do
      let(:prominence) { 'requester_only' }

      it 'does not show the request if not logged in' do
        show(info_request)
        expect(response).to have_http_status(:not_found)
      end

      it 'does not show the request if logged in but not the requester' do
        sign_in_as FactoryBot.create(:user)
        show(info_request)
        expect(response).to have_http_status(:not_found)
      end

      it 'shows the request to the requester' do
        sign_in_as info_request.user
        show(info_request)
        expect_requester_page_for(info_request)
      end

      it 'shows the request to an admin' do
        sign_in_as admin
        show(info_request)
        expect_admin_page_for(info_request)
      end
    end
  end

  describe 'when searching for an authority' do
    it 'returns matching bodies' do
      body = public_bodies(:geraldine_public_body)
      stub_typeahead_results(items: [body], total: 1)
      get select_authority_path, params: { query: 'Quango' }

      expect(response).to have_http_status(:ok)
      expect(page.at_css('form#search_form')).to be_present
      results = page.css('#authority_search_ahead_results .body_listing')
      expect(results.size).to eq(1)
      expect(results.first.at_css('.head a').text).to eq(body.name)
      expect(page.at_css('#typeahead_response').text).
        to include('1 matching authority')
    end

    describe 'when params[:pro] is true' do
      context 'and an account is signed in' do
        let(:user) { FactoryBot.create(:user) }

        before do
          sign_in_as user
        end

        it 'uses the inbox form even with a client override' do
          get select_authority_path
          expect(response).to redirect_to(new_alaveteli_pro_info_request_path)
        end
      end

      context 'and nobody is signed in' do
        it 'does not redirect to the inbox form' do
          get select_authority_path
          expect(response).to be_successful
          expect(page.at_css('form#search_form')).to be_present
        end
      end
    end

    describe 'when params[:pro] is not set' do
      it 'sends every signed-in account to the inbox form' do
        user = FactoryBot.create(:user)
        sign_in_as user
        get select_authority_path
        expect(response).to redirect_to(new_alaveteli_pro_info_request_url)
      end
    end
  end

  describe 'when creating a new request' do
    include_context 'with request limits on'

    let(:user) { users(:bob_smith_user) }
    let(:body) { public_bodies(:geraldine_public_body) }

    def write_form
      page.at_css('form#write_form')
    end

    # Read as a browser reads it, with its line endings made plain.
    def letter
      Nokogiri::HTML5(response.body).
        at_css('textarea#outgoing_message_body').text
    end

    def error_messages
      page.css('#errorExplanation li').map(&:text)
    end

    it 'redirects to front page if no public body specified' do
      get new_request_path
      expect(response).to redirect_to(frontpage_url)
    end

    it 'sends a signed-in account to the inbox form, even with no public ' \
       'body' do
      sign_in_as user
      get new_request_path
      expect(response).to redirect_to(new_alaveteli_pro_info_request_url)
    end

    it "shows the 'bad contact' page when a body has no email address" do
      body.request_email = ''
      body.save!
      get new_request_path, params: { public_body_id: body.id }
      expect(response).to have_http_status(:ok)
      expect(page.at_css('h1.page-band__title').text).
        to eq("Missing contact details for '#{body.name}'")
      expect(write_form).to be_nil
    end

    it 'adds noindex, nofollow header' do
      get new_request_path, params: { public_body_id: body.id }
      expect(response.headers['X-Robots-Tag']).to eq 'noindex, nofollow'
    end

    context 'the outgoing message includes an email address' do
      context 'there is no logged in user' do
        it 'displays a flash error message without escaping the HTML' do
          post new_request_path, params: {
            info_request: {
              public_body_id: body.id,
              title: 'Test Request'
            },
            outgoing_message: { body: 'me@here.com' },
            submitted_new_request: 1,
            preview: 1
          }

          expect(page.css('div#error p')).not_to be_empty
          expect(page.text).not_to include('<p>')
          expect(page.text).
            to include('You do not need to include your email')
        end
      end
    end

    context 'the outgoing message includes a postcode' do
      it 'displays an error message warning about the postcode' do
        post new_request_path, params: {
          info_request: {
            public_body_id: body.id,
            title: 'Test Request'
          },
          outgoing_message: { body: 'SW1A 1AA' },
          submitted_new_request: 1,
          preview: 1
        }

        expect(response).to have_http_status(:ok)
        expect(page.at_css('form#preview_form')).to be_present
        expect(page.at_css('div#error').text).
          to include('Your request contains a postcode')
      end
    end

    it 'sends every signed-in account to the inbox form' do
      user = FactoryBot.create(:user)
      public_body = FactoryBot.create(:public_body)
      sign_in_as user
      get new_request_to_body_path(url_name: public_body.url_name)
      expected_url = new_alaveteli_pro_info_request_url(
        public_body: public_body.url_name
      )
      expect(response).to redirect_to(expected_url)
    end

    it 'accepts a public body parameter' do
      get new_request_path, params: { public_body_id: body.id }
      expect(response).to have_http_status(:ok)
      expect(write_form).to be_present
      expect(write_form.at_css("input[name='info_request[public_body_id]']")[
        'value'
      ]).to eq(body.id.to_s)
      expect(page.at_css('#to_public_body').text).to include(body.name)
    end

    it 'offers a default text for the request' do
      get new_request_path, params: { public_body_id: body.id }
      expect(write_form.at_css("input[name='info_request[public_body_id]']")[
        'value'
      ]).to eq(body.id.to_s)
      expect(letter).to match(/\ADear Geraldine Quango,\n\n+Yours faithfully,/)
    end

    it 'allows the default text to be set via the default_letter param' do
      get new_request_to_body_path(url_name: body.url_name),
          params: { default_letter: 'test' }
      expect(letter).
        to match(/\ADear Geraldine Quango,\n\ntest\n\n+Yours faithfully,/)
    end

    it 'displays one meaningful error message when no message body is ' \
       'added' do
      post new_request_path, params: {
        info_request: { public_body_id: body.id },
        outgoing_message: { body: '' },
        submitted_new_request: 1,
        preview: 1
      }
      expect(error_messages).
        to include('Please enter your letter requesting information')
      expect(error_messages.grep(/is invalid/)).to be_empty
    end

    it "gives an error and shows the form again when a summary isn't given" do
      post new_request_path,
           params: {
             info_request: { public_body_id: body.id },
             outgoing_message: {
               body: 'This is a silly letter. It is too short to be ' \
                     'interesting.'
             },
             submitted_new_request: 1,
             preview: 1
           }
      expect(response).to have_http_status(:unprocessable_content)
      expect(error_messages).
        to include('Please enter a summary of your request')
      expect(write_form).to be_present
    end

    it 'redirects to the sign up page when input is good and nobody is ' \
       'logged in' do
      params = {
        info_request: {
          public_body_id: body.id,
          title: 'Why is your quango called Geraldine?', tag_string: ''
        },
        outgoing_message: {
          body: 'This is a silly letter. It is too short to be interesting.'
        },
        submitted_new_request: 1, preview: 0
      }
      post new_request_path, params: params
      expect(response).
        to redirect_to(signup_path)
      pending = PendingRequestDraft.last
      expect(JSON.parse(pending.payload)['title']).
        to eq(params[:info_request][:title])
    end

    it 'redirects to the frontpage if the action is sent the invalid ' \
       'public_body param' do
      post new_request_path, params: {
        info_request: {
          public_body: body.id,
          title: 'Why Geraldine?',
          tag_string: ''
        },
        outgoing_message: { body: 'This is a silly letter.' },
        submitted_new_request: 1,
        preview: 1
      }
      expect(response).to redirect_to frontpage_url
    end

    it 'shows preview when input is good' do
      post new_request_path, params: {
        info_request: {
          public_body_id: body.id,
          title: 'Why is your quango called Geraldine?',
          tag_string: ''
        },
        outgoing_message: {
          body: 'This is a silly letter. It is too short to be interesting.'
        },
        submitted_new_request: 1,
        preview: 1
      }
      expect(response).to have_http_status(:ok)
      expect(page.at_css('h1.page-band__title').text).
        to eq('Preview your request')
      expect(page.at_css('form#preview_form')).to be_present
      expect(write_form).to be_nil
    end

    context 'when re-editing a request' do
      before do
        post new_request_path, params: {
          info_request: {
            public_body_id: body.id,
            title: 'Why is your quango called Geraldine?',
            tag_string: ''
          },
          outgoing_message: {
            body: 'This is a silly letter. It is too short to be ' \
                  'interesting.'
          },
          submitted_new_request: 1,
          preview: 0,
          reedit: 'Re-edit this request'
        }
      end

      it 'allows re-editing of a request' do
        expect(response).to have_http_status(:ok)
        expect(write_form).to be_present
        expect(page.at_css('form#preview_form')).to be_nil
      end

      it 're-editing preserves the message body' do
        expect(letter).
          to include('This is a silly letter. It is too short to be ' \
                     'interesting.')
      end
    end
  end

  describe 'when someone else views a request' do
    it 'does not show the request to them' do
      sign_in_as users(:silly_name_user)
      get show_request_path('why_do_you_have_such_a_fancy_dog')
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'when the site is in read_only mode' do
    before do
      allow(AlaveteliConfiguration).
        to receive(:read_only).
        and_return('Down for maintenance')
    end

    it 'redirects to the frontpage_url' do
      get new_request_path
      expect(response).to redirect_to frontpage_url
    end

    it 'shows a flash message to alert the user' do
      get new_request_path
      expect(flash[:notice]).to match(/Down for maintenance/)
    end
  end

  describe 'GET details' do
    let(:info_request) { FactoryBot.create(:info_request) }

    def details
      get details_request_path(url_title: info_request.url_title)
    end

    it 'shows the event history of the request' do
      sign_in_as info_request.user
      details
      expect(response).to have_http_status(:ok)
      heading = page.at_css('h1.page-band__title')
      expect(heading.text).to include('Details of request')
      expect(heading.text).to include(info_request.title)
      expect(page.css('h2').map(&:text)).to include('Event history')
    end

    it 'links to the request it describes' do
      sign_in_as info_request.user
      details
      link = page.at_css('h1.page-band__title a')
      expect(link.text).to eq(info_request.title)
      expect(link['href']).to eq(request_path(info_request))
    end

    context 'when the request is hidden' do
      before do
        info_request.prominence = 'hidden'
        info_request.save!
      end

      it 'returns a 404' do
        details
        expect(response).to have_http_status(:not_found)
      end

      it 'does not show the hidden request page' do
        details
        expect(response).to have_http_status(:not_found)
        expect(page.css('h1.page-band__title').map(&:text)).
          not_to include('This request is not published')
      end
    end

    context 'when the request is private to its requester' do
      before do
        info_request.update!(prominence: 'requester_only')
      end

      it 'is not found for someone else' do
        details
        expect(response).to have_http_status(:not_found)
      end
    end

    it 'adds noindex, nofollow header' do
      sign_in_as info_request.user
      details
      expect(response.headers['X-Robots-Tag']).to eq 'noindex, nofollow'
    end
  end

  describe 'GET download_entire_request' do
    after { FileUtils.rm_rf(RegulatorPack.storage_dir) }

    def download(info_request)
      get download_entire_request_path(url_title: info_request.url_title)
    end

    def zip_entries
      entries = {}
      Zip::File.open_buffer(response.body) do |zip|
        zip.each { |entry| entries[entry.name] = entry.get_input_stream.read }
      end
      entries
    end

    context 'when the request is private to its requester' do
      let(:user) { FactoryBot.create(:user) }
      let(:pro_user) { FactoryBot.create(:pro_user) }
      let(:info_request) do
        FactoryBot.create(:info_request, :requester_only, user: pro_user)
      end

      context 'and the user is not logged in' do
        it 'is not found' do
          download(info_request)
          expect(response).to have_http_status(:not_found)
        end
      end

      context 'and the user is logged in but not the owner' do
        before do
          sign_in_as user
        end

        it 'is not found' do
          download(info_request)
          expect(response).to have_http_status(:not_found)
        end
      end

      context 'and the user is the owner' do
        before do
          sign_in_as pro_user
        end

        it 'queues the regulator pack job and redirects back' do
          expect { download(info_request) }.
            to have_enqueued_job(InfoRequest::RegulatorPackJob).
            with(info_request, pro_user)
          expect(response).
            to redirect_to(show_request_path(info_request.url_title))
        end
      end
    end

    context 'when the request is unclassified' do
      it 'does not render the status forms or actions in the pack correspondence' do
        info_request = FactoryBot.create(:info_request_with_incoming)
        info_request.update(awaiting_description: true)
        info_request.expire
        sign_in_as info_request.user
        show(info_request)
        expect(status_form).to be_present

        token = RegulatorPack.new(info_request, user: info_request.user).build!
        get download_regulator_pack_path(token: token)
        expect(response).to be_successful
        text = zip_entries.fetch('correspondence.txt')
        expect(text).to include(info_request.title)
        expect(text).not_to include('What best describes the status')
        expect(text).not_to include('Update the status of this request')
        expect(text).not_to include('Submit status')
      end
    end
  end

  describe 'GET show_request_event' do
    def show_event(event)
      get info_request_event_path(info_request_event_id: event.id)
    end

    context 'when the event is an incoming message' do
      let(:event) { FactoryBot.create(:response_event) }

      it 'returns a 301 status' do
        sign_in_as event.info_request.user
        show_event(event)
        expect(response.status).to eq(301)
      end

      it 'redirects to the incoming message path' do
        sign_in_as event.info_request.user
        show_event(event)
        expect(response).
          to redirect_to(incoming_message_path(event.incoming_message))
      end

      it 'is not found when the request is private' do
        event.info_request.update!(prominence: 'requester_only')
        show_event(event)
        expect(response).to have_http_status(:not_found)
      end
    end

    context 'when the event is an outgoing message' do
      let(:event) { FactoryBot.create(:sent_event) }

      it 'returns a 301 status' do
        sign_in_as event.info_request.user
        show_event(event)
        expect(response.status).to eq(301)
      end

      it 'redirects to the outgoing message path' do
        sign_in_as event.info_request.user
        show_event(event)
        expect(response).
          to redirect_to(outgoing_message_path(event.outgoing_message))
      end

      it 'is not found when the request is private' do
        event.info_request.update!(prominence: 'requester_only')
        show_event(event)
        expect(response).to have_http_status(:not_found)
      end
    end

    context 'for any other kind of event' do
      let(:event) { FactoryBot.create(:info_request_event) }

      it 'returns a 301 status' do
        sign_in_as event.info_request.user
        show_event(event)
        expect(response.status).to eq(301)
      end

      it 'redirects to the request path' do
        sign_in_as event.info_request.user
        show_event(event)
        expect(response).
          to redirect_to(show_request_path(event.info_request.url_title))
      end
    end
  end
end
