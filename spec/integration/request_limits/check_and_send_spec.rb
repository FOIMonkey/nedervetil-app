require 'spec_helper'

RSpec.describe 'Check and send under the request limits', feature: :alaveteli_pro do
  include_context 'with incoming attention off'

  include_context 'with request limits on'

  let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:council) {
    FactoryBot.create(:public_body,
                      name: 'Northmoor District Council',
                      tag_string: 'local_council ' \
                                                'district_council')
  }

  before do
    sign_in(owner)
  end

  def check(title, letter)
    post '/pro/info_requests', params: {
      info_request: { title: title, public_body_id: council.id },
      outgoing_message: { body: RequestLetter.join(letter,
                                                   council.name,
                                                   owner.name) },
      review: 1
    }
    follow_redirect! while response.redirect?
    Nokogiri::HTML(response.body)
  end

  def send_from(page)
    form = page.css('form').find { |candidate|
      candidate.at_css('#submit_button')
    }
    post form['action'], params: {
      draft_id: form.at_css('input[name="draft_id"]')['value'],
      review_token: form.at_css('input[name="review_token"]')['value']
    }
  end

  it 'sends from Check and send through the Pro limit, which refuses a second send within the minute' do
    get new_alaveteli_pro_info_request_path(public_body: council.url_name,
                                            question: 'How many abandoned ' \
                                                      'vehicles in 2025?',
                                            check: 1)
    expect(Nokogiri::HTML(response.body).at_css('.request-suggestions').text).
      to include('How many abandoned vehicles were removed?')
    first = check('Fly-tipping 2025',
                  'Please provide the number of fly-tipping incidents in 2025.')
    send_from(first)
    expect(response).to be_redirect
    expect(owner.info_requests.count).to eq(1)

    second = check('Bin rounds 2025',
                   'Please provide the bin collection rounds for 2025.')
    draft = owner.draft_info_requests.last
    deliveries = ActionMailer::Base.deliveries.size
    send_from(second)
    expect(response).to have_http_status(:too_many_requests)
    expect(response.body).
      to include('You’ve sent a request in the last minute.',
                 'Your draft is saved.')
    expect(owner.draft_info_requests).to include(draft)
    expect(owner.info_requests.count).to eq(1)
    expect(ActionMailer::Base.deliveries.size).to eq(deliveries)
  end
end
