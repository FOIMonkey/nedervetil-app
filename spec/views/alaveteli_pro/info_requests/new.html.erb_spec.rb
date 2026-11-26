require 'spec_helper'

RSpec.describe "alaveteli_pro/info_requests/new" do
  let(:draft_info_request) { FactoryBot.create(:draft_info_request) }
  let(:info_request) { InfoRequest.from_draft(draft_info_request) }
  let(:outgoing_message) { info_request.outgoing_messages.first }

  def assign_variables
    assign :draft_info_request, draft_info_request
    assign :info_request, info_request
    assign :outgoing_message, outgoing_message
    view.extend(RequestJourney::NavigationHelper)
    allow(view).to receive(:current_user).and_return(draft_info_request.user)
  end

  it "starts with the request's authority, which can be changed" do
    assign_variables
    render
    expect(rendered).to have_css('.request-sheet__to',
                                 text: "To #{info_request.public_body.name}")
    expect(rendered).to have_button('Change authority')
  end

  it "searches for an authority on the new request page" do
    assign_variables
    assign :step, :who
    render
    expect(rendered).to have_css(
      "form#authority_form[method=get]" \
      "[action='#{new_alaveteli_pro_info_request_path}'] input[name=query]"
    )
  end

  it "includes a hidden field for the body id" do
    assign_variables
    render
    expect(rendered).to have_css(
      "input[type=hidden][name='info_request[public_body_id]']" \
      "[value='#{info_request.public_body.id}']",
      visible: :all
    )
  end
end
