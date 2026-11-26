require 'spec_helper'

RSpec.describe 'The front page and version', type: :request do
  # Signs in through the form and checks it worked.
  def sign_in_as(user)
    sign_in(user)
    expect(response).to have_http_status(:see_other)
  end

  def page
    Nokogiri::HTML(response.body)
  end

  describe 'GET version' do
    let(:mock_stats) do
      double(alaveteli_git_commit: 'abc123')
    end

    before do
      expect(Statistics::General).to receive(:new).and_return(mock_stats)
      get version_path(format: :json)
    end

    it 'renders json stats about the install' do
      parsed_body = JSON.parse(response.body).symbolize_keys
      expect(parsed_body).to eq(
        alaveteli_git_commit: 'abc123',
        alaveteli_version: ALAVETELI_VERSION,
        ruby_version: RUBY_VERSION,
        public_document_count: Disclosures::Document.listed.count
      )
    end

    it 'responds as JSON' do
      expect(response.media_type).to eq('application/json')
    end
  end

  describe 'when showing the frontpage' do
    it 'renders the front page successfully' do
      get frontpage_path
      expect(response).to be_successful
    end

    it 'renders the front page with default language' do
      get frontpage_path
      expect(page.at_css('html')['lang']).to eq('en')
    end

    it 'renders the front page with a different default language' do
      with_default_locale('es') do
        get frontpage_path
        expect(page.at_css('html')['lang']).to eq('es')
      end
    end

    it 'does not generate a feed URL for successful requests' do
      get frontpage_path
      expect(page.css('link[type="application/atom+xml"]')).to be_empty
      expect(response.body).not_to include('Successful requests')
    end

    it 'renders the front page with default language and ignores the ' \
       'browser setting' do
      allow(AlaveteliConfiguration).to receive(:use_default_browser_language).
        and_return(false)
      accept_language = 'en-GB,en-US;q=0.8,en;q=0.6'
      with_default_locale('es') do
        get frontpage_path,
            headers: { 'HTTP_ACCEPT_LANGUAGE' => accept_language }
        expect(page.at_css('html')['lang']).to eq('es')
      end
    end

    it "renders the front page with browser-selected language when there's " \
       'no default set' do
      allow(AlaveteliConfiguration).to receive(:use_default_browser_language).
        and_return(true)
      accept_language = 'es-ES,en-GB,en-US;q=0.8,en;q=0.6'
      get frontpage_path, headers: { 'HTTP_ACCEPT_LANGUAGE' => accept_language }
      expect(page.at_css('html')['lang']).to eq('es')
    end

    it "doesn't raise an error when there's no user matching the one in " \
       'the session' do
      user = FactoryBot.create(:user)
      sign_in_as user
      user.destroy!
      get frontpage_path
      expect(response).to be_successful
    end

    describe 'when using locales' do
      it 'uses our test PO files rather than the application one' do
        cookies[:locale] = 'es'
        get frontpage_path
        expect(response).to have_http_status(:ok)
        expect(page.at_css('html')['lang']).to eq('es')
        expect(response.body).to match(/XOXO/)
      end
    end

    describe 'when handling logged-in users' do
      let(:user) { FactoryBot.create(:user) }

      before do
        sign_in_as user
      end

      # Signed in, the inbox is the home page, whatever the account's role.
      it 'sends the account to the inbox' do
        get frontpage_path
        expect(response).to redirect_to alaveteli_pro_dashboard_path
      end

      # The home page redirects before its after_actions run, so these use a
      # page that renders for a signed-in account.
      it 'refreshes the bounded authentication proof on an ordinary request' do
        travel 1.hour do
          get version_path(format: :json)
          proof = session['warden.user.user.session'][
            Authentication::Session::KEY
          ]
          expect(proof['at']).to be_within(1).of(Time.current.to_i)
        end
        expect(session[:user_id]).to be_nil
      end

      it 'ignores an orphaned post_redirect parameter' do
        get frontpage_path(post_redirect: 1)
        expect(response).to redirect_to alaveteli_pro_dashboard_path
      end
    end
  end
end
