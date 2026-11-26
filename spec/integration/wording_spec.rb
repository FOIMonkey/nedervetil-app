require 'spec_helper'

RSpec.describe 'Wording' do
  describe 'a request that produced no information' do
    let(:info_request) do
      FactoryBot.create(:info_request).tap do |r|
        r.set_described_state('not_held')
      end
    end

    it 'says so in one way, whether it was refused or not held' do
      admin = FactoryBot.create(:admin_user)
      sign_in(admin)
      get "/request/#{info_request.url_title}"
      status = Nokogiri::HTML(response.body).at_css('.request-status').text

      expect(status).to include('No information was provided by')
      expect(status).not_to match(/refused|not have|not hold/i)
    end

    it 'says so in the same words on the requester’s own page' do
      sign_in(info_request.user)
      get "/request/#{info_request.url_title}"
      step = Nokogiri::HTML(response.body).at_css('.next-step').text

      expect(step).to include('No information')
      expect(step).not_to match(/refused|not have|not hold/i)
    end
  end

  describe 'a request that is not published' do
    let(:info_request) do
      # Requests are created private.
      FactoryBot.create(:info_request)
    end

    it 'is described to a visitor as unpublished, not as removed or hidden' do
      get "/request/#{info_request.url_title}"
      expect(response.status).to eq(404)
      expect(response.body).not_to include(info_request.title)
      get '/request/missing_private_request'
      expect(response.status).to eq(404)
    end

    it 'is described to its requester as private' do
      post '/profile/sign_in', params: {
        user_signin: { email: info_request.user.email,
                       password: 'jonespassword' }
      }
      get "/request/#{info_request.url_title}"

      expect(response.status).to eq(200)
      expect(response.body).
        to include('Private: only you and the site’s admins can see it.')
      expect(response.body).not_to include('various reasons')
    end
  end
end
