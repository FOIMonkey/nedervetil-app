require 'spec_helper'

RSpec.describe "admin/users/show" do
  before do
    assign :info_requests, InfoRequest.none.paginate(page: 1, per_page: 100)
    assign :info_request_batches, []
    assign :admin_user, user_being_viewed
  end

  # An admin may log in as anyone else whose account isn't closed (#93).
  context 'when the current user cannot login as the user being viewed' do
    let(:current_user) { FactoryBot.create(:admin_user) }
    let(:user_being_viewed) { FactoryBot.create(:user).tap(&:close!) }

    it 'should not show the list of post redirects' do
      with_feature_enabled(:alaveteli_pro) do
        allow(controller).to receive(:current_user).and_return(current_user)
        render template: 'admin/users/show', locals: {
          current_user: current_user
        }
        expect(rendered).not_to match('Post redirects')
      end
    end
  end

  context 'when the current user can login as the user being viewed' do
    let(:current_user) { FactoryBot.create(:admin_user) }
    let(:user_being_viewed) { FactoryBot.create(:pro_user) }

    it 'should show the list of post redirects' do
      with_feature_enabled(:alaveteli_pro) do
        allow(controller).to receive(:current_user).and_return(current_user)
        render template: 'admin/users/show', locals: {
          current_user: current_user
        }
        expect(rendered).to match('Post redirects')
      end
    end
  end
end
