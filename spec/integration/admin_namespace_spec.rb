require 'spec_helper'

RSpec.describe 'Admin controllers under Admin::' do
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:ordinary) { FactoryBot.create(:user) }
  let(:info_request) { FactoryBot.create(:info_request, user: ordinary) }

  include_context 'consider all requests remote'
  before do
    allow(AlaveteliConfiguration).to receive(:skip_admin_auth).and_return(false)
  end

  def page
    Nokogiri::HTML(response.body)
  end

  pages = %w[
    /admin /admin/timeline /admin/stats /admin/spam_addresses
    /admin/announcements /admin/holidays /admin/holiday_imports/new
    /admin/mail_server_logs /admin/bodies
    /admin/change_requests /admin/info_request_events
    /admin/outgoing_messages /admin/users /admin/users/active
  ].freeze

  describe 'who can see them' do
    pages.each do |path|
      it "asks a visitor to sign in at #{path}" do
        get path
        expect(response).to redirect_to(signin_url)
      end

      it "asks someone who isn't an admin to sign in at #{path}" do
        sign_in(ordinary)
        get path
        expect(response).to have_http_status(:not_found)
      end

      it "shows #{path} to an admin, in the admin layout" do
        sign_in(admin)
        get path
        expect(response).to have_http_status(:ok)
        expect(page.at_css('body.admin #admin-bar')).to be_present
      end
    end

    it 'stops at the next page for an admin who has lost the role' do
      sign_in(admin)
      get '/admin/users'
      expect(response).to have_http_status(:ok)
      admin.remove_role(:admin)
      get '/admin/users'
      expect(response).to have_http_status(:not_found)
    end

    it 'skips the privacy gate on every admin path, as before' do
      sign_in(admin)
      get "/admin/requests/#{info_request.id}"
      expect(response).to have_http_status(:ok)
      get "/admin/users/#{ordinary.id}"
      expect(response).to have_http_status(:ok)
    end

    it 'sends every admin controller through the same base' do
      anonymous_controller = Class.new(ActionController::Base)
      expect(anonymous_controller.controller_path).to be_nil
      Rails.application.eager_load!
      # View/helper specs leave anonymous TestController subclasses with
      # admin/... paths in descendants.
      controllers = ActionController::Base.descendants.select do |controller|
        next false if controller <= ActionView::TestCase::TestController

        controller.controller_path.to_s.start_with?('admin')
      end
      expect(controllers).not_to include(anonymous_controller)
      expect(controllers.size).to be > 18
      expect(controllers - [AdminController]).to all(be < AdminController)
      expect(controllers.map(&:controller_path).grep(/\Aadmin_/)).to eq([])
    end
  end

  describe 'templates found by name' do
    it 'shows timeline events, which are skipped if their partial is not found' do
      info_request.log_event('edit', editor: 'someone', old_title: 'Old title',
                                     title: 'New title')
      sign_in(admin)
      get '/admin/timeline', params: { start_date: '1970-01-01' }
      expect(page.at_css('.timeline, #timeline, body').text).
        to include('was edited by administrator')
    end

    it 'renders the response offered when accepting a change request' do
      change_request = FactoryBot.create(
        :update_body_request, user: ordinary,
                              public_body_email: 'new@example.org'
      )
      sign_in(admin)
      get "/admin/bodies/#{change_request.public_body.id}/edit",
          params: { change_request_id: change_request.id }
      expect(page.at_css('textarea[name="response"]').text).
        to include('Thanks for your suggestion to update the email address')
    end
  end

  describe 'normal admin sign in with legacy emergency settings' do
    before do
      allow(AlaveteliConfiguration).
        to receive(:disable_emergency_user).and_return(false)
    end

    it 'offers only normal sign in from the dashboard' do
      get '/admin'
      follow_redirect!
      expect(page.at_css('#signin_form')).to be_present
      expect(page.at_css('#superuser_message')).to be_nil
    end

    it 'offers only normal sign in for a redirect saved before the dashboard moved' do
      get '/profile/sign_in', params: { token: 'invented-retired-token' }
      expect(page.at_css('#signin_form')).to be_present
      expect(page.at_css('#superuser_message')).to be_nil
    end

    it 'is not offered from another admin page' do
      get '/admin/users'
      follow_redirect!
      expect(page.at_css('#superuser_message')).to be_nil
    end
  end

  # Rails picks this key from the controller's class name unless it's told.
  describe 'flat JSON bodies' do
    {
      Admin::SpamAddressesController => 'admin_spam_address',
      Admin::AnnouncementsController => 'admin_announcement',
      Admin::HolidaysController => 'admin_holiday',
      Admin::HolidayImportsController => 'admin_holiday_import',
      Admin::GeneralController => 'admin_general',
      Admin::MailServerLogsController => 'admin_mail_server_log',
      Admin::PublicBodiesController => 'admin_public_body',
      Admin::PublicBodyChangeRequestsController =>
        'admin_public_body_change_request',
      Admin::RequestsController => 'admin_request',
      Admin::IncomingMessagesController => 'admin_incoming_message',
      Admin::OutgoingMessagesController => 'admin_outgoing_message',
      Admin::InfoRequestEventsController => 'admin_info_request_event',
      Admin::RawEmailsController => 'admin_raw_email',
      Admin::UsersController => 'admin_user',
      Admin::Users::SlugsController => 'admin_user_slug'
    }.each do |controller, key|
      it "keeps #{key} on #{controller}" do
        options = controller._wrapper_options
        expect(options.name.to_s).to eq(key)
        expect(options.format).to eq(%i[json])
        expect(options.include).to be_nil
      end
    end

    it 'does not apply a flat body to a record' do
      outgoing_message = info_request.outgoing_messages.first
      written = outgoing_message.body
      sign_in(admin)
      put "/admin/outgoing_messages/#{outgoing_message.id}",
          params: { body: 'Changed' }.to_json,
          headers: { 'CONTENT_TYPE' => 'application/json' }
      expect(outgoing_message.reload.body).to eq(written)
    end
  end
end
