require 'spec_helper'

RSpec.describe 'Pro support', feature: :alaveteli_pro do
  include_context 'with incoming attention off'

  let(:owner) { FactoryBot.create(:user, trusted: true) }
  let(:other_user) { FactoryBot.create(:user, trusted: true) }
  let(:authority) { FactoryBot.create(:public_body) }

  before do
    allow(Rails.application.config).
      to receive(:consider_all_requests_local).and_return(false)
  end

  def batch_draft_params
    { alaveteli_pro_draft_info_request_batch: {
      title: 'Private batch targets',
      body: 'Please supply the requested records.',
      public_body_ids: authority.id
    } }
  end

  it 'allows the manually granted owner to use the existing dashboard without billing' do
    sign_in(owner)
    get alaveteli_pro_dashboard_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('<h1 class="page-band__title">Home</h1>')
  end

  it 'redirects an anonymous dashboard visitor to sign in' do
    get alaveteli_pro_dashboard_path
    expect(response.location).to include('/profile/sign_in')
  end

  it 'rejects a signed-in ordinary account from the dashboard' do
    sign_in(other_user)
    get alaveteli_pro_dashboard_path
    expect(response).to have_http_status(:ok)
  end

  it 'does not create a batch draft for an anonymous caller' do
    expect {
      post '/pro/draft_info_request_batches',
           params: batch_draft_params
    }.not_to change(AlaveteliPro::DraftInfoRequestBatch, :count)
    expect(response.location).to include('/profile/sign_in')
  end

  it 'does not create a batch draft for a signed-in ordinary account' do
    sign_in(other_user)
    expect {
      post '/pro/draft_info_request_batches',
           params: batch_draft_params
    }.to change(AlaveteliPro::DraftInfoRequestBatch, :count).by(1)
  end

  it 'keeps single-request draft, preview, send and reply permanently ' \
     'private' do
    sign_in(owner)
    get new_alaveteli_pro_info_request_path(public_body: authority.url_name,
                                            question: 'The requested records',
                                            go: 1)
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(response.body).
      to include('Only you and the site’s admins can see it.')

    post '/pro/info_requests', params: {
      info_request: { title: 'Private single request',
                      public_body_id: authority.id },
      outgoing_message: { body: 'Please supply the requested records.' },
      review: 1
    }
    draft = owner.draft_info_requests.last
    follow_redirect! while response.redirect?
    expect(response.body).
      to include('Only you and the site’s admins can see it.')
    expect(response.body).not_to include('public on')

    post '/pro/info_requests', params: { draft_id: draft.id, review_token: RequestJourney::Review.token(draft) }
    request = owner.info_requests.last
    expect(request.reload.prominence).to eq('requester_only')
    expect(request.use_notifications?).to be(true)
    expect(ActionMailer::Base.deliveries.size).to eq(1)
    receive_incoming_mail(info_request: request)
    message = request.incoming_messages.last
    attachment = FactoryBot.create(:foi_attachment, incoming_message: message)
    expect(message.prominence).to eq('normal')
    expect(Ability.guest.can?(:read, request)).to be(false)
    expect(Ability.guest.can?(:read, message)).to be(false)
    expect(Ability.guest.can?(:read, attachment)).to be(false)
    expect(ActionMailer::Base.deliveries.size).to eq(1)
    expect(owner.notifications.last.info_request_event.incoming_message).
      to eq(message)
  end

  it 'keeps a batch draft private and sends private children' do
    sign_in(owner)
    post '/pro/draft_info_request_batches', params: batch_draft_params
    draft = owner.draft_info_request_batches.last
    get new_alaveteli_pro_info_request_batch_path(draft_id: draft.id)
    expect(response.body).to include('stays private')
    get preview_new_alaveteli_pro_info_request_batch_path(draft_id: draft.id)
    expect(response.body).to include('stays private')
    expect(response.body).to include('id="submit_button"')
    post '/pro/info_request_batches', params: { draft_id: draft.id }
    batch = owner.info_request_batches.last
    batch.create_batch!
    expect(batch.info_requests.map(&:prominence)).to eq(['requester_only'])
    expect(batch.info_requests.map(&:use_notifications?)).to eq([true])
  end

  describe 'a batch draft edited with a summary too long to send' do
    let(:draft) do
      sign_in(owner)
      post '/pro/draft_info_request_batches', params: batch_draft_params
      owner.draft_info_request_batches.last
    end

    def edit(title: "Edited #{'x' * 300}", **button)
      put "/pro/draft_info_request_batches/#{draft.id}", params: {
        alaveteli_pro_draft_info_request_batch: {
          title: title, body: 'The edited letter.',
          public_body_ids: [authority.id]
        }, **button
      }
      follow_redirect! while response.redirect?
    end

    it 'shows the edits and the error at the preview, with nothing to ' \
       'send' do
      edit(preview: true)

      expect(response.body).to include('The edited letter.')
      expect(response.body).to include('Please keep the summary short')
      expect(response.body).
        not_to include('Please supply the requested records.')
      expect(response.body).not_to include('id="submit_button"')
    end

    # A request's summary has its spaces closed up and a batch's does not,
    # so here the example request is short enough and only the batch
    # objects. Its error is the only one, and must be shown.
    it 'says why at the preview when only the batch finds the summary ' \
       'too long' do
      title = "Bin  sites #{'x' * 190}"
      expect([title.length, title.squeeze(' ').length]).to eq([201, 200])

      edit(title: title, preview: true)

      expect(response.body).to include('Please keep the summary short')
      expect(response.body).to include('The edited letter.')
      expect(response.body).not_to include('id="submit_button"')
    end

    it 'sends nothing while the summary is too long' do
      edit

      expect {
        post '/pro/info_request_batches', params: { draft_id: draft.id }
      }.not_to change(InfoRequestBatch, :count)
      expect(response.body).to include('Please keep the summary short')
      expect(draft.reload.body).to eq('The edited letter.')
    end

    it 'keeps the edits when the draft is saved' do
      edit

      expect(response.body).to include('The edited letter.')
      expect(response.body).to include('Your draft has been saved!')
      expect(draft.reload.body).to eq('The edited letter.')
    end
  end

  it 'prevents another Pro account from editing the owner batch draft' do
    draft = FactoryBot.create(:draft_info_request_batch, user: owner)
    sign_in(FactoryBot.create(:user))
    put "/pro/draft_info_request_batches/#{draft.id}",
        params: batch_draft_params
    expect(response).to have_http_status(:not_found)
    expect(draft.reload.title).not_to eq('Private batch targets')
  end

  # The marketing sign-up was removed with Pro pricing (see doc/FORK.md).
  it 'has no account-request form and sends no interest email' do
    get '/pro'
    expect(response).to have_http_status(:not_found)
    post '/pro', params: { account_request: {
      full_name: 'Visitor', email: 'visitor@example.com', reason: 'Access'
    } }
    expect(response).to have_http_status(:not_found)
    expect(ActionMailer::Base.deliveries).to be_empty
  end

  describe 'batch privacy' do
    let(:batch) {
      FactoryBot.create(:info_request_batch,
                        :sent,
                        user: owner,
                        public_body_count: 2)
    }

    it 'hides title, target counts and children from anonymous and other-account viewers' do
      get info_request_batch_path(batch)
      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include(batch.title)
      sign_in(other_user)
      get info_request_batch_path(batch)
      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include(batch.title)
    end

    it 'hides a pending batch before child requests exist' do
      pending_batch = FactoryBot.create(:info_request_batch,
                                        user: owner,
                                        public_bodies: [authority])
      get info_request_batch_path(pending_batch)
      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include(pending_batch.title, authority.name)
    end

    it 'keeps a sent batch private after its children have been removed' do
      batch.info_requests.destroy_all
      batch.reload
      get info_request_batch_path(batch)
      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include(batch.title)
    end

    it 'keeps the owner in Pro and shows all their private children' do
      sign_in(owner)
      get info_request_batch_path(batch)
      expect(response).
        to redirect_to(show_alaveteli_pro_batch_request_url(batch))
      follow_redirect!
      expect(response).to have_http_status(:ok)
      batch.info_requests.
        each { |request| expect(response.body).to include(request.title) }
      expect(response.body).to include('stays private')
    end

    it 'allows an authorized site admin to inspect the private batch' do
      sign_in(FactoryBot.create(:admin_user))
      get info_request_batch_path(batch)
      expect(response).to have_http_status(:ok)
      batch.info_requests.
        each { |request| expect(response.body).to include(request.title) }
    end

    it 'lists requests in the dashboard’s piles, with no batch cards' do
      single = FactoryBot.create(:info_request, user: owner)
      batch
      sign_in(owner)
      get alaveteli_pro_info_requests_path
      html = Nokogiri::HTML(response.body)
      expect(html.css('.requests-piles a').map { |link| link.text.squish }).
        to include(a_string_starting_with('All'),
                   a_string_starting_with('Needs you'),
                   a_string_starting_with('Finished'))
      expect(html.at_css(%(.pile__row[data-request-id="#{single.id}"]))).
        to be_present
      expect(html.at_css("#info-request-batch-#{batch.id}")).to be_nil
      expect(html.at_css('.dashboard-left-column')).to be_nil
    end
  end

  describe 'private correspondence metadata endpoints' do
    let(:info_request) {
      FactoryBot.create(:info_request,
                        user: owner,
                        title: 'Private endpoint title')
    }
    let(:incoming_event) {
      FactoryBot.create(:response_event, info_request: info_request)
    }
    let(:outgoing_event) do
      FactoryBot.create(:sent_event,
                        info_request: info_request,
                        outgoing_message: info_request.outgoing_messages.first)
    end

    def expect_hidden_metadata(supplied_slug: false)
      expect(response).to have_http_status(:not_found)
      expect(response.location).to be_nil
      expect(response.body).not_to include(info_request.title)
      return if supplied_slug

      expect(response.body).not_to include(info_request.url_title)
    end

    it 'hides the private ZIP login reason from anonymous and other-account callers' do
      expect { get download_entire_request_path(info_request.url_title) }.
        not_to change(PostRedirect, :count)
      expect_hidden_metadata(supplied_slug: true)
      sign_in(other_user)
      expect { get download_entire_request_path(info_request.url_title) }.
        not_to change(PostRedirect, :count)
      expect_hidden_metadata(supplied_slug: true)
    end

    it 'hides private request and message URLs from anonymous and other-account event callers' do
      generic_event = FactoryBot.create(:info_request_event,
                                        info_request: info_request)
      events = [incoming_event, outgoing_event, generic_event]
      events.each do |event|
        expect { get info_request_event_path(event.id) }.
          not_to change(PostRedirect, :count)
        expect_hidden_metadata
      end
      sign_in(other_user)
      events.each do |event|
        get info_request_event_path(event.id)
        expect_hidden_metadata
      end
    end

    it 'preserves private event redirects for the owner and authorized admin' do
      event = incoming_event
      sign_in(owner)
      get info_request_event_path(event.id)
      expect(response).to have_http_status(:moved_permanently)
      expect(response.location).
        to include(info_request.url_title,
                   "#incoming-#{event.incoming_message_id}")
      sign_in(FactoryBot.create(:admin_user))
      get info_request_event_path(event.id)
      expect(response).to have_http_status(:moved_permanently)
      expect(response.location).
        to include(info_request.url_title,
                   "#incoming-#{event.incoming_message_id}")
    end

    it 'serves private attachment content only to its authorized owner' do
      attachment = FactoryBot.create(:foi_attachment,
        incoming_message: incoming_event.incoming_message,
        body: 'Private endpoint attachment content')
      path = get_attachment_path(info_request.url_title,
        incoming_message_id: attachment.incoming_message_id,
        part: attachment.url_part_number, file_name: attachment.filename)
      get path
      expect(response).to have_http_status(:not_found)
      expect(response.body).
        not_to include(info_request.title,
                       'Private endpoint attachment content')
      sign_in(owner)
      get path
      expect(response).to have_http_status(:ok)
      expect(response.body).to eq('Private endpoint attachment content')
    end
  end

  describe 'private batch CSV downloads' do
    let(:batch) {
      FactoryBot.create(:info_request_batch,
                        :sent,
                        user: owner,
                        public_body_count: 2)
    }
    let(:csv_path) { "/pro/info_request_batches/#{batch.id}/download.csv" }

    it 'denies visitors and another Pro account before rendering private CSV data' do
      get csv_path
      expect(response).to have_http_status(:not_found)
      expect(response.headers['Location']).to be_nil
      expect(response.body).not_to include(batch.title)
      sign_in(FactoryBot.create(:user))
      get csv_path
      expect(response).to have_http_status(:not_found)
      expect(response.body).
        not_to include(batch.title, *batch.info_requests.map(&:url_title))
    end

    it 'returns the private children CSV to their Pro owner' do
      sign_in(owner)
      get csv_path
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('text/csv')
      rows = CSV.parse(response.body, headers: true)
      expect(rows.size).to eq(2)
      expect(rows.map { |row| row['request_url'] }).to match_array(
        batch.info_requests.
          map { |child| "http://test.host/request/#{child.url_title}" }
      )
      expect(rows.map { |row| row['authority_name'] }).
        to match_array(batch.public_bodies.map(&:name))
    end
  end

  it 'delivers the existing daily digest for Pro single and batch responses once' do
    single = FactoryBot.create(:info_request, user: owner)
    batch = FactoryBot.create(:info_request_batch, :sent, user: owner,
                                                          public_body_count: 2)
    receive_incoming_mail(info_request: single)
    batch.info_requests.
      each { |info_request| receive_incoming_mail(info_request: info_request) }
    expect(ActionMailer::Base.deliveries).to be_empty
    due = owner.notifications.maximum(:send_after)
    travel_to(due + 1.minute) { NotificationMailer.send_daily_notifications }
    expect(ActionMailer::Base.deliveries.size).to eq(1)
    mail = ActionMailer::Base.deliveries.first
    expect(mail.to).to eq([owner.email])
    expect(mail.subject).to eq('3 replies')
    expect(mail.body.to_s).to include(single.title, batch.title, '2 replies')
    decoded = CGI.unescape(mail.body.to_s)
    expect(decoded).to include('/profile/sign_in?r=')
    expect(decoded).to include("#incoming-#{single.incoming_messages.last.id}")
    expect(decoded).
      to include(
        Rails.application.routes.url_helpers.info_request_batch_path(batch)
      )
    expect(owner.notifications.unseen.count).to eq(0)
    travel_to(due + 2.minutes) { NotificationMailer.send_daily_notifications }
    expect(ActionMailer::Base.deliveries.size).to eq(1)
  end

  it 'declares its callbacks and handlers once when prepare callbacks repeat' do
    2.times { Rails.application.reloader.prepare! }
    callbacks = AlaveteliPro::DraftInfoRequestBatchesController._process_action_callbacks
    expect(callbacks.count { |callback|
      callback.filter == :require_inbox_sign_in
    }).to eq(1)
    request_callbacks = RequestController._process_action_callbacks
    expect(request_callbacks.count { |callback|
      callback.filter == :require_event_message_read
    }).to eq(1)
    handler = ['CanCan::AccessDenied', :render_permission_denied]
    expect(
      AlaveteliPro::BatchDownloadsController.rescue_handlers.count(handler)
    ).to eq(1)
    sign_in(owner)
    get alaveteli_pro_dashboard_path
    expect(response).to have_http_status(:ok)
  end
end
