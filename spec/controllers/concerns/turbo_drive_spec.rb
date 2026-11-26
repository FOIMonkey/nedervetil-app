require 'spec_helper'

RSpec.describe TurboDrive, type: :controller do
  controller(ApplicationController) do
    turbo_drive false, only: :index

    def index
      render plain: turbo_drive?.to_s
    end

    def show
      render plain: turbo_drive?.to_s
    end
  end

  it 'opts the named actions out' do
    get :index
    expect(response.body).to eq('false')
  end

  it 'leaves every other action on Turbo Drive' do
    get :show, params: { id: 1 }
    expect(response.body).to eq('true')
  end
end

RSpec.describe HelpController, 'and Turbo Drive', type: :controller do
  render_views

  let(:html) { Nokogiri::HTML(response.body) }

  it 'turns off hover prefetch and gives Turbo the CSP nonce' do
    get :about
    expect(html.at('meta[name="turbo-prefetch"]')['content']).to eq('false')
    expect(html.at('meta[name="csp-nonce"]')['content']).to be_present
  end

  it 'asks for a full page load when a deploy changes the stylesheet' do
    get :about
    stylesheet =
      html.at('link[rel="stylesheet"][href*="responsive/application"]')
    expect(stylesheet['data-turbo-track']).to eq('reload')
  end

  it 'lets Turbo Drive visit a page that is not on the opt-out list' do
    get :about
    expect(html.at('meta[name="turbo-visit-control"]')).to be_nil
    expect(html.at('body')['data-turbo']).to be_nil
  end

  it 'lets Turbo keep a copy of a visitor’s page for Back' do
    get :about
    expect(html.at('meta[name="turbo-cache-control"]')).to be_nil
  end

  it 'keeps no copy of a page rendered for someone signed in' do
    sign_in FactoryBot.create(:user)
    get :about
    expect(html.at('meta[name="turbo-cache-control"]')['content']).
      to eq('no-cache')
  end

  it 'gives a page on the opt-out list full page loads' do
    allow(controller).to receive(:turbo_drive?).and_return(false)
    get :about
    expect(html.at('meta[name="turbo-visit-control"]')['content']).
      to eq('reload')
    expect(html.at('body')['data-turbo']).to eq('false')
  end

  # Loading it again would fetch the form empty and lose what was typed.
  it 'keeps a failed submit on such a page where it is, submitting in full' do
    allow(controller).to receive(:turbo_drive?).and_return(false)
    post :contact, params: {
      submitted_contact_form: 1,
      contact: { name: '', email: '', subject: '', message: 'Hello' }
    }
    expect(response).to have_http_status(422)
    expect(html.at('meta[name="turbo-visit-control"]')).to be_nil
    expect(html.at('body')['data-turbo']).to eq('false')
  end
end
