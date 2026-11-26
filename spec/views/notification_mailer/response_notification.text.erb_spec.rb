require 'spec_helper'

RSpec.describe "notification_mailer/response_notification" do
  let(:notification) { FactoryBot.create(:notification) }
  let(:info_request_event) { notification.info_request_event }
  let(:info_request) { info_request_event.info_request }

  def render_summary
    assign(:summary,
           IncomingAttention::Summary.new(notification.user, [notification]))
    render
  end

  it "does not add HTMLEntities to the authority name" do
    info_request.public_body.update!(name: "Test's Authority")
    render_summary
    expect(response).to include("Test's Authority replied.")
    expect(response).to include("Test's Authority · Replied")
  end

  it "does not add HTMLEntities to the request title" do
    info_request.update!(title: "Here's a request & more")
    render_summary
    expect(response).to include("Here's a request & more")
  end
end
