require 'spec_helper'

RSpec.describe "public_body/list" do
  before do
    @pb = FactoryBot.create(:public_body, name: 'Test Quango',
                                          short_name: 'tq')
    pb_info_requests = [1, 2, 3, 4]

    allow(@pb).to receive(:info_requests).and_return(pb_info_requests)

    @public_bodies = WillPaginate::Collection.create(1, 10, 1) do |pager|
      pager.replace([@pb])
    end

    assign(:public_body, @pb)
    assign(:page, 1)
    assign(:description, 'test')
    assign(:per_page, 10)
    assign(:public_bodies, @public_bodies)

    view.extend(RequestJourney::NavigationHelper)
    allow(view).to receive(:current_user).and_return(nil)
  end

  it "should be successful" do
    render
    expect(controller.response).to be_successful
  end

  it "should show the body's name" do
    render
    expect(response).to have_css('div.head', text: "Test Quango")
  end

  it "should not show the number of requests to the body" do
    render
    expect(response).not_to match "3 requests"
  end
end
