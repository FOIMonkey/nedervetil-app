require 'spec_helper'

RSpec.describe 'URLs of removed inherited features' do
  include DisclosuresHelpers
  include_context 'with production error pages'

  let(:owner) { FactoryBot.create(:user) }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:thread) {
    FactoryBot.create(:info_request, user: owner,
                                     title: 'Removedfeaturetoken request')
  }

  def viewers
    { 'a visitor' => nil, 'the requester' => owner, 'an admin' => admin }
  end

  def visit_as(viewer, method, url)
    viewer ? sign_in(viewer) : reset!
    public_send(method, url)
  end

  def expect_not_found(method, url)
    viewers.each do |name, viewer|
      visit_as(viewer, method, url)
      expect(response).to have_http_status(:not_found),
                          "#{method.upcase} #{url} as #{name}"
      expect(response.body).not_to include('Removedfeaturetoken')
      expect(response.headers['Location']).to be_nil
    end
  end

  it 'gives a 404 for the request game' do
    expect_not_found(:get, '/categorise/play')
    expect_not_found(:post, '/categorise/play')
    expect_not_found(:post, '/categorise/stop')
    expect_not_found(:get, "/request/#{thread.url_title}/categorise")
  end

  it 'gives a 404 for the public statistics page' do
    expect_not_found(:get, '/statistics')
  end

  it 'answers the old JSON and CSV versions as any unknown URL' do
    { '/statistics.json' => '/no-such-page.json',
      '/statistics.csv' => '/no-such-page.csv',
      '/categorise/play.json' => '/no-such-page.json' }.each do |old, unknown|
      viewers.each do |name, viewer|
        visit_as(viewer, :get, unknown)
        expected = response.status
        visit_as(viewer, :get, old)
        expect(response.status).to eq(expected), "#{old} as #{name}"
        expect(response).not_to be_successful
        expect(response.body).not_to include('Removedfeaturetoken')
      end
    end
  end

  it 'gives a 404 for request widgets and widget votes' do
    expect_not_found(:get, "/request/#{thread.url_title}/widget")
    expect_not_found(:get, "/request/#{thread.url_title}/widget/new")
    expect_not_found(:post, "/request/#{thread.url_title}/widget_votes")
  end

  it 'gives a 404 for the ATI showcase' do
    expect_not_found(:get, '/access-to-information-around-the-world')
  end

  it 'gives a 404 for projects and their admin pages' do
    expect_not_found(:get, '/p/sometoken')
    expect_not_found(:get, '/projects/1')
    expect_not_found(:get, '/projects/1/classify')
    expect_not_found(:get, '/pro/projects')
    expect_not_found(:get, '/pro/projects/new')
    expect_not_found(:get, '/admin/projects')
  end

  it 'gives a 404 for user-to-user messages' do
    expect_not_found(:get, "/user/contact/#{owner.url_name}")
    expect_not_found(:post, "/user/contact/#{owner.url_name}")
  end

  it 'gives a 404 for the "About me" profile text page' do
    expect_not_found(:get, '/profile/about_me/edit')
    expect_not_found(:put, '/profile/about_me')
    expect_not_found(:patch, '/profile/about_me')
    expect_not_found(:get, '/profile/set_about_me')
    expect_not_found(:post, '/profile/set_about_me')
  end

  it 'gives a 404 for share-by-link URLs' do
    expect_not_found(:get, '/r/sometoken')
    expect_not_found(:get, '/r/sometoken/response/1/attach/2')
    expect_not_found(:get, '/r/sometoken/response/1/attach/html/2/file')
    expect_not_found(:post, "/request/#{thread.url_title}/public_tokens")
    expect_not_found(:delete, "/request/#{thread.url_title}/public_tokens")
  end

  it 'gives a 404 for citations and their admin pages' do
    expect_not_found(:get, '/citations')
    expect_not_found(:get, "/request/#{thread.url_title}/citations/new")
    expect_not_found(:post, "/request/#{thread.url_title}/citations")
    expect_not_found(:get, '/info_request_batch/1/citations/new')
    expect_not_found(:get, '/admin/citations')
  end

  it 'gives a 404 for tracks, their feeds and admin pages' do
    expect_not_found(:get, "/request/#{thread.url_title}/track")
    expect_not_found(:get, "/request/#{thread.url_title}/feed")
    expect_not_found(:get, '/track/list/recent')
    expect_not_found(:get, '/track/body/tgq')
    expect_not_found(:get, "/track/user/#{owner.url_name}")
    expect_not_found(:get, "/feed/user/#{owner.url_name}")
    expect_not_found(:get, '/track/search/bob')
    expect_not_found(:get, '/track/update/1')
    expect_not_found(:post, '/track/update/1')
    expect_not_found(:post, '/track/delete_all_type')
    expect_not_found(:get, '/track/feed/1')
    expect_not_found(:get, '/profile/river')
    expect_not_found(:get, '/admin/tracks')
  end

  it 'sends the list, authority and search feeds to the documents feed' do
    { '/feed/list/recent' => disclosure_documents_path(feed: '1'),
      '/feed/body/tgq' => disclosure_documents_path(feed: '1', body: 'tgq'),
      '/feed/search/bob' => disclosure_documents_path(feed: '1', q: 'bob') }.
      each do |old, new|
        viewers.each do |name, viewer|
          visit_as(viewer, :get, old)
          expect(response).to redirect_to(new), "#{old} as #{name}"
        end
      end
  end

  it 'sends the request listings and the request search to the documents' do
    %w[/browse /list /list/successful /list/climate/awaiting /list/all
       /list/recent].each do |old|
      viewers.each do |name, viewer|
        visit_as(viewer, :get, old)
        expect(response).to redirect_to('/documents'), "#{old} as #{name}"
        expect(response).to have_http_status(:moved_permanently), old
      end
    end

    { '/search' => '/documents',
      '/search?query=bob' => '/documents?q=bob',
      '/search/bob' => '/documents?q=bob',
      '/search/bob/all' => '/documents?q=bob',
      '/search/bob/requests' => '/documents?q=bob',
      '/search/bob/users/newest' => '/documents?q=bob',
      '/search/bob/bodies/relevant/advanced' => '/documents?q=bob',
      '/search/tag:climate/requests' => '/documents?q=tag%3Aclimate',
      '/advancedsearch' => '/documents',
      '/advancedsearch?query=bob' => '/documents?q=bob' }.each do |old, new|
      viewers.each do |name, viewer|
        visit_as(viewer, :get, old)
        expect(response).to redirect_to(new), "#{old} as #{name}"
        expect(response).to have_http_status(:moved_permanently), old
      end
    end
  end

  it 'gives no JSON version of a request or an account' do
    ["/request/#{thread.url_title}.json", "/user/#{owner.url_name}.json"].
      each do |url|
      visit_as(nil, :get, url)
      expect(response).to have_http_status(:not_found), url
      [owner, admin].each do |viewer|
        visit_as(viewer, :get, url)
        expect(response).to have_http_status(:not_acceptable), url
        expect(response.body).not_to include('Removedfeaturetoken', owner.name)
      end
    end
  end

  it 'gives a 404 for the wall and the request typeahead' do
    expect_not_found(:get, "/user/#{owner.url_name}/wall")
    expect_not_found(:get, '/request/search_ahead?q=bob')
  end

  it 'answers the old authority API URLs as any unknown URL' do
    [[:post, '/api/v2/request.json', '/no-such-page.json'],
     [:get, '/api/v2/request/1.json', '/no-such-page.json'],
     [:post, '/api/v2/request/1.json', '/no-such-page.json'],
     [:post, '/api/v2/request/1/update.json', '/no-such-page.json'],
     [:get, '/api/v2/body/1/request_events.atom', '/no-such-page.atom']].
      each do |method, old, unknown|
        viewers.each do |name, viewer|
          visit_as(viewer, method, unknown)
          expected = response.status
          visit_as(viewer, method, old)
          expect(response.status).to eq(expected), "#{old} as #{name}"
          expect(response).not_to be_successful
        end
      end
  end

  it 'gives a 404 for the annotation pages and their admin pages' do
    expect_not_found(:get, "/request/#{thread.url_title}/annotate")
    expect_not_found(:post, "/request/#{thread.url_title}/annotate")
    expect_not_found(:post,
                     "/request/#{thread.url_title}/annotate?preview=1")
    expect_not_found(:get, '/admin/comments')
    expect_not_found(:get, '/admin/comments/1/edit')
    expect_not_found(:put, '/admin/comments/1')
    expect_not_found(:delete, '/admin/comments/1')
    expect_not_found(:post, '/admin/users/modify_comment_visibility')
  end

  # RemoveComments refuses to run while comment events exist, but the event
  # types stay valid, so a row like these must never break a page.
  it 'shows request and admin pages that hold legacy comment events' do
    gone = { gid: 'gid://app/Comment/1' }
    author = { gid: "gid://app/User/#{owner.id}" }
    { 'comment' => { comment: gone },
      'edit_comment' => { comment: gone, editor: 'admin', old_body: 'Old',
                          body: 'New', old_visible: true, visible: true },
      'hide_comment' => { comment: gone, editor: 'admin',
                          old_visible: true, visible: false },
      'destroy_comment' => { comment: gone, comment_user: author,
                             editor: 'admin' },
      'report_comment' => { comment: gone, editor: author, reason: 'Why',
                            message: 'A note',
                            old_attention_requested: false,
                            attention_requested: true } }.
      each do |type, params|
        FactoryBot.create(:info_request_event, info_request: thread,
                                               event_type: type,
                                               params: params)
      end

    { owner => ["/request/#{thread.url_title}",
                "/request/#{thread.url_title}/details"],
      admin => ['/admin/timeline?start_date=1970-01-01T00:00:00Z',
                '/admin/timeline?event_type=info_request_event',
                "/admin/requests/#{thread.id}",
                '/admin/info_request_events'] }.
      each do |viewer, urls|
        urls.each do |url|
          visit_as(viewer, :get, url)
          expect(response).to have_http_status(:ok), url
        end
      end
    visit_as(owner, :get, "/request/#{thread.url_title}/download")
    expect(response).to have_http_status(:found)
    visit_as(admin, :get, '/admin/timeline?event_type=info_request_event')
    expect(response.body).to include("had 'comment' done to it")
  end

  it 'gives a 404 for the blog and its admin pages' do
    expect_not_found(:get, '/blog')
    expect_not_found(:get, '/admin/blog_posts')
    expect_not_found(:get, '/admin/blog_posts/1/edit')
  end

  it 'gives a 404 for officer uploads and their admin URL' do
    expect_not_found(:get, "/request/#{thread.url_title}/upload")
    expect_not_found(:post, "/request/#{thread.url_title}/upload")
    expect_not_found(:post, "/admin/requests/#{thread.id}/generate_upload_url")
  end

  it 'gives a 404 for the AI insights admin pages' do
    insights = "/admin/requests/#{thread.id}/insights"
    expect_not_found(:get, "#{insights}/new")
    expect_not_found(:post, insights)
    expect_not_found(:get, "#{insights}/1")
    expect_not_found(:delete, "#{insights}/1")
  end

  it 'gives a 404 for Pro pricing, billing and sign-up',
     feature: :alaveteli_pro do
    expect_not_found(:get, '/pro')
    expect_not_found(:post, '/pro')
    expect_not_found(:get, '/pro/training')
    expect_not_found(:get, '/pro/pricing')
    expect_not_found(:get, '/plans/pro')
    expect_not_found(:get, '/pro/pages/journalists')
    expect_not_found(:get, '/profile/subscriptions')
    expect_not_found(:post, '/profile/subscriptions')
    expect_not_found(:delete, '/profile/subscriptions/1')
    expect_not_found(:get, '/profile/subscriptions/1/authorise')
    expect_not_found(:put, '/profile/subscriptions/payment_method')
    expect_not_found(:get, '/profile/invoices')
    expect_not_found(:post, '/pro/subscriptions/stripe-webhook')
  end

  it 'leaves the ATI showcase off the home page' do
    get '/'
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('frontpage_ati_network')
    expect(response.body).
      not_to include('/access-to-information-around-the-world')
  end

  # The request page here doesn't show the sidebar's actions box, so its
  # partial is rendered directly.
  it 'leaves the widget and share links out of the request actions box' do
    allow(AlaveteliConfiguration).
      to receive(:donation_url).and_return('https://example.org/donate')
    html = ApplicationController.render(partial: 'request/act',
                                        locals: { info_request: thread })
    expect(html).to include('Donate')
    expect(html).not_to include('Share this request')
    expect(html).not_to include('Create a widget for this request')
    expect(html).not_to include('act-link-icon--widget')
  end

  it 'leaves the actions box empty without a donation link' do
    allow(AlaveteliConfiguration).to receive(:donation_url).and_return('')
    html = ApplicationController.render(partial: 'request/act',
                                        locals: { info_request: thread })
    expect(html.strip).to be_empty
  end

  it 'leaves the share link off the request sent notices' do
    batch = FactoryBot.create(:info_request_batch, user: owner)
    [
      ApplicationController.render(partial: 'request/request_sent',
                                   assigns: { info_request: thread }),
      ApplicationController.render(partial: 'info_request_batch/batch_sent',
                                   assigns: { info_request_batch: batch })
    ].each do |html|
      expect(html).to include('We will email you')
      expect(html).not_to include('Share this request')
      expect(html).not_to include('link to this page')
    end
  end

  it 'gives a 404 for the embargo and extension actions' do
    with_feature_enabled(:alaveteli_pro) do
      visit_as(nil, :get, '/pro/dashboard')
      expect(response).not_to have_http_status(:not_found)

      expect_not_found(:post, '/pro/embargoes')
      expect_not_found(:delete, '/pro/embargoes/1')
      expect_not_found(:post, '/pro/embargoes/destroy_batch')
      expect_not_found(:post, '/pro/embargo_extensions')
      expect_not_found(:post, '/pro/embargo_extensions/create_batch')
    end
  end

  [false, true].each do |pro|
    context "with Pro #{pro ? 'on' : 'off'}", feature: { alaveteli_pro: pro } do
      it 'answers the old editor recovery URLs as any unknown URL' do
        attachment = AttachmentFixtures.deliver(
          thread, [['records.txt', 'text/plain', "Removedfeaturetoken text\n"]]
        ).get_attachments_for_display.first
        document = Disclosures::Creation.new(user: owner,
                                             attachment: attachment,
                                             kind: 'released_records').create!
        bases = ["/manage/attachments/#{attachment.id}",
                 "/documents/#{document.public_id}"]
        bases.product([[:get, 'editor_draft'], [:put, 'editor_draft'],
                       [:delete, 'editor_draft'],
                       [:post, 'editor_draft/recover']],
                      [{}, { 'Accept' => 'application/json' }]).
          each do |base, (method, path), headers|
            viewers.each do |name, viewer|
              viewer ? sign_in(viewer) : reset!
              public_send(method, "#{base}/no-such-page", headers: headers)
              expected = response.status
              public_send(method, "#{base}/#{path}", headers: headers)
              described = "#{method.upcase} #{base}/#{path} #{headers} " \
                          "as #{name}"
              expect(response.status).to eq(expected), described
              expect(response).not_to be_successful, described
              expect(response.body).not_to include('Removedfeaturetoken')
            end
          end
      end
    end
  end

  it 'keeps the old statistics redirect' do
    viewers.each do |name, viewer|
      visit_as(viewer, :get, '/body_statistics')
      expect(response).to redirect_to('/statistics#public_bodies'), name
      expect(response).to have_http_status(:moved_permanently)
    end
  end

  it 'keeps the old request redirects, still only for those who can read it' do
    old_urls = {
      "/categorise/request/#{thread.url_title}" =>
        "/request/#{thread.url_title}/categorise",
      "/request/#{thread.id}/widget" =>
        "/request/#{thread.url_title}/widget",
      "/request/#{thread.id}/widget/new" =>
        "/request/#{thread.url_title}/widget/new",
      "/annotate/request/#{thread.url_title}" =>
        "/request/#{thread.url_title}/annotate"
    }
    old_urls.each do |old_url, new_url|
      visit_as(nil, :get, old_url)
      expect(response).to have_http_status(:not_found), old_url
      expect(response.headers['Location']).to be_nil

      [owner, admin].each do |viewer|
        visit_as(viewer, :get, old_url)
        expect(response).to redirect_to(new_url)
        expect(response).to have_http_status(:moved_permanently)
      end
    end
  end
end
