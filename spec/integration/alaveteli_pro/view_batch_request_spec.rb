require 'spec_helper'
require 'integration/alaveteli_dsl'
require 'support/shared_examples_for_viewing_requests'

RSpec.describe 'viewing requests that are part of a batch in alaveteli_pro' do
  let(:pro_user) { FactoryBot.create(:pro_user) }
  let!(:pro_user_session) { login(pro_user) }

  let(:batch) do
    FactoryBot.create(:info_request_batch, :sent, user: pro_user)
  end

  let(:info_request) { batch.info_requests.first }

  context 'a pro user viewing one of their own requests' do
    it 'allows the user to view the request' do
      using_pro_session(pro_user_session) do
        browse_pro_request(info_request.url_title)
        expect(page).to have_content(info_request.title)
      end
    end

    it 'shows that the request is private' do
      using_pro_session(pro_user_session) do
        browse_pro_request(info_request.url_title)
        expect(page).to have_css(".page-band__label", text: "Private")
        expect(page).to have_css('.request-foot',
                                 text: 'Private: only you and the site’s ' \
                                       'admins can see it.')
      end
    end

    it 'does not prompt the user to publish their request' do
      using_pro_session(pro_user_session) do
        browse_pro_request(info_request.url_title)
        expect(page).to have_no_content "Publish request"
      end
    end

    include_examples 'keeps the request private'
    include_examples 'allows followups'

    context 'the user does not have pro status' do
      it 'does not show the privacy sidebar' do
        using_pro_session(pro_user_session) do
          browse_pro_request(info_request.url_title)
          expect(page).to have_no_css("h2", text: "Privacy")
        end
      end
    end

    context 'the request has received a response' do
      it_behaves_like 'a request with response'
    end
  end
end
