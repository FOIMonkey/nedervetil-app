require 'spec_helper'

RSpec.describe "request_mailer/stopped_responses" do
  let(:user) { FactoryBot.create(:user, name: "Test Us'r") }
  let(:body) { FactoryBot.create(:public_body, name: "Apostrophe's") }
  let(:request) do
    FactoryBot.create(:info_request,
                      public_body: body,
                      user: user,
                      title: "Request apostrophe's data")
  end

  before do
    allow(AlaveteliConfiguration).to receive(:site_name).
      and_return("l'Information")
    assign(:contact_email, "nospam@example.com")
  end

  it "does not add HTMLEntities to the FOI law title" do
    allow(request).to receive(:legislation).and_return(
      FactoryBot.build(:legislation, short: "Test's Law")
    )
    assign(:info_request, request)
    render
    expect(response).to match("an Test's Law request")
  end

  it "omits the request title and requester name" do
    assign(:info_request, request)
    render
    expect(response).not_to include(request.title)
    expect(response).not_to include(user.name)
  end

  it "does not add HTMLEntities to the public body name" do
    assign(:info_request, request)
    render
    expect(response).to match("on behalf of Apostrophe's to reply")
  end

  it "does not add HTMLEntities to the contact email" do
    assign(:info_request, request)
    assign(:contact_email, "a'b@example.com")
    render
    expect(response).to match("email a'b@example.com to ask us to reopen")
  end

  it "does not add HTMLEntities to the site name" do
    assign(:info_request, request)
    render
    expect(response).to match("the l'Information team")
  end
end
