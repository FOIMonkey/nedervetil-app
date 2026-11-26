require 'spec_helper'

RSpec.describe 'outgoing_mailer/initial_request' do
  let(:body) do
    FactoryBot.create(:public_body, name: "Apostrophe's",
                                    request_email: "a'b@example.com")
  end
  let(:request) { FactoryBot.create(:info_request, public_body: body) }
  let(:outgoing_message) { request.outgoing_messages.first }

  it 'renders the letter without a footer naming the public body' do
    assign(:info_request, request)
    assign(:outgoing_message, outgoing_message)
    render
    expect(response).to eq("Some information please\n")
  end

  it 'renders the letter without a footer naming the FOI law' do
    allow(request).to receive(:legislation).and_return(
      FactoryBot.build(:legislation, full: "Test's Law")
    )
    assign(:info_request, request)
    assign(:outgoing_message, outgoing_message)
    render
    expect(response).to eq("Some information please\n")
  end

  it 'renders the letter without a footer giving the public body email' do
    assign(:info_request, request)
    assign(:outgoing_message, outgoing_message)
    render
    expect(response).to eq("Some information please\n")
  end
end
