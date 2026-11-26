# The page asking for a message to go with a new status. The including group
# defines message_path, the page's address for info_request.
RSpec.shared_examples 'adding classification message action' do
  let(:info_request) { FactoryBot.create(:info_request) }
  let(:page) { Nokogiri::HTML(response.body) }

  before do
    sign_in info_request.user
    get message_path
  end

  def field_value(name)
    page.at_css("input[name='#{name}']")&.[]('value')
  end

  it 'shows the message form for the request' do
    expect(response).to have_http_status(:ok)
    expect(field_value('url_title')).to eq(info_request.url_title)
  end

  it 'sends the described state with the message' do
    expect(field_value('classification[described_state]')).
      to eq('error_message')
  end

  it 'titles the page for the described state' do
    expect(page.at_css('title').text).
      to include("I've received an error message")
    expect(page.at_css('h1.page-band__title').text).
      to include("I've received an error message")
  end
end
