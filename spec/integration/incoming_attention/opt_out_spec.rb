require 'spec_helper'

RSpec.describe IncomingAttention::OptOut do
  describe 'the account setting' do
    before do
      allow(Rails.application.config).
        to receive(:consider_all_requests_local).and_return(false)
    end
    let(:user) { FactoryBot.create(:user) }

    it 'asks a visitor to sign in' do
      get '/profile/ai_reading'
      expect(response).to redirect_to(signin_path(r: '/profile/ai_reading'))
      post '/profile/ai_reading', params: { ai_reading: 'off' }
      expect(described_class.count).to eq(0)
    end

    it 'turns reading off and on again for the signed-in account only' do
      other = FactoryBot.create(:user)
      sign_in(user)
      get '/profile/ai_reading'
      expect(response.body).
        to include('Reading replies with AI', 'not sent to the AI service')
      post '/profile/ai_reading', params: { ai_reading: 'off',
                                            user_id: other.id }
      expect(described_class.opted_out?(user)).to be true
      expect(described_class.opted_out?(other)).to be false
      get '/profile/ai_reading'
      expect(
        Nokogiri::HTML(response.body).at_css('input[value=off]')['checked']
      ).to be_present
      post '/profile/ai_reading', params: { ai_reading: 'on' }
      expect(described_class.opted_out?(user)).to be false
      expect(response.headers['Cache-Control']).to include('no-store')
    end

    it 'changes nothing without an explicit choice, or during maintenance' do
      sign_in(user)
      described_class.set!(user, true)
      [{},
       { ai_reading: '' },
       { ai_reading: 'yes' },
       { ai_reading: ['on'] },
       { ai_reading: { x: 'on' } }].each do |params|
        post '/profile/ai_reading', params: params
        expect(response).to redirect_to('/profile/ai_reading')
        expect(described_class.opted_out?(user)).to be(true), params.inspect
      end
      follow_redirect!
      expect(response.body).to include('Choose On or Off.')
      allow(AlaveteliConfiguration).
        to receive(:read_only).and_return('Back soon.')
      get '/profile/ai_reading'
      expect(response).to have_http_status(:ok)
      post '/profile/ai_reading', params: { ai_reading: 'on' }
      expect(response).to redirect_to(frontpage_url)
      expect(described_class.opted_out?(user)).to be true
    end

    it 'links to the setting from your own profile, not from anyone else’s' do
      other = FactoryBot.create(:user)
      sign_in(user)
      get "/user/#{user.url_name}"
      expect(response.body).to include('/profile/ai_reading')
      get "/user/#{other.url_name}"
      expect(response.body).not_to include('/profile/ai_reading')
    end
  end
end
