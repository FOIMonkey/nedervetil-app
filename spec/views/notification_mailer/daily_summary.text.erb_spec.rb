require 'spec_helper'

RSpec.describe "notification_mailer/daily_summary" do
  let(:public_body) { FactoryBot.create(:public_body, name: "l'Information") }
  let(:info_request) do
    FactoryBot.create(:info_request, public_body: public_body,
                                     title: "Who's who & why")
  end
  let(:notifications) do
    Array.new(2) do
      event = FactoryBot.create(:response_event, info_request: info_request)
      FactoryBot.create(:daily_notification, info_request_event: event)
    end
  end

  it "does not add HTMLEntities to authority and request names" do
    assign(:summary,
           IncomingAttention::Summary.new(info_request.user, notifications))
    render
    expect(response).to include("l'Information replied.")
    expect(response).to include("Who's who & why")
    expect(response).to include("l'Information · 2 replies")
  end
end
