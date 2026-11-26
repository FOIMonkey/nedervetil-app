require 'spec_helper'

RSpec.describe "admin/public_bodies/show" do
  let(:public_body) { FactoryBot.create(:public_body) }

  before do
    assign :public_body, public_body
    assign :info_requests, InfoRequest.none.paginate(page: 1, per_page: 100)
    assign :versions, []
  end

  it 'shows the authority without an API key' do
    allow(controller).to receive(:current_user).
      and_return(FactoryBot.create(:admin_user))
    render template: 'admin/public_bodies/show'
    expect(rendered).to include(public_body.name)
    expect(rendered).not_to include('Api key')
  end
end
