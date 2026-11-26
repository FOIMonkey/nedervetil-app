require 'spec_helper'

RSpec.describe 'The complaint page', feature: :alaveteli_pro do
  include_context 'with incoming attention off'

  let(:user) do
    FactoryBot.create(:pro_user, name: 'Rowan Requester', trusted: true)
  end
  let(:start) { Time.zone.parse('2026-09-07 10:00') }

  before do
    allow(Rails.application.config).
      to receive(:consider_all_requests_local).and_return(false)
  end

  def request_sent(body = FactoryBot.create(:public_body))
    travel_to(start) do
      FactoryBot.create(:info_request, user: user, public_body: body)
    end
  end

  # A session expires ApplicationController::SESSION_TTL after the last
  # request, so this signs in at the test's own time.
  def visit(path, at:)
    travel_to(at) do
      sign_in(user)
      get path
    end
    Nokogiri::HTML(response.body)
  end

  it 'shows each nation only its own route, with current links' do
    scottish_request =
      request_sent(FactoryBot.create(:public_body, tag_string: 'scotland'))
    scottish = visit("/help/unhappy/#{scottish_request.url_title}",
                     at: Time.zone.parse('2026-10-09 12:00'))
    expect(scottish.css('a').map { |link| link['href'] }).
      to include('https://www.foi.scot/appeal')
    expect(scottish.text).not_to include('ICO')
    expect(scottish.text).
      to include('the Commissioner can only act after a review')

    reset!
    english_request = request_sent
    english = visit("/help/unhappy/#{english_request.url_title}",
                    at: Time.zone.parse('2026-10-09 12:00'))
    expect(english.css('a').map { |link| link['href'] }).
      to include('https://ico.org.uk/make-a-complaint/' \
                 'foi-and-eir-complaints/foi-and-eir-complaints/')
    expect(english.text).not_to include('ico.gov.uk',
                                        'itspublicknowledge',
                                        'Scottish Information Commissioner')
  end

  it 'gives the requester their case file' do
    request = request_sent(
      FactoryBot.create(:public_body,
                        name: 'Northmoor County Council',
                        tag_string: 'local_council county_council')
    )
    travel_to(Time.zone.parse('2026-09-28 11:00')) do
      AttachmentFixtures.deliver(
        request,
        [['Routes 2025.csv', 'text/csv', "route,road\n1,A1\n"]]
      )
    end
    page = visit("/help/unhappy/#{request.url_title}",
                 at: Time.zone.parse('2026-09-29 12:00'))
    file = page.at_css('.case-file')
    expect(file.css('.case-file__list li').size).to eq(2)
    expect(file.at_css('a.button')['href']).
      to eq(download_entire_request_path(url_title: request.url_title))
  end

  it 'leaves a reply hidden from the requester out of their case file' do
    request = request_sent
    travel_to(Time.zone.parse('2026-09-28 11:00')) do
      AttachmentFixtures.deliver(
        request,
        [['Routes 2025.csv', 'text/csv', "route,road\n1,A1\n"]]
      )
    end
    request.reload.incoming_messages.last.update!(prominence: 'hidden')
    page = visit("/help/unhappy/#{request.url_title}",
                 at: Time.zone.parse('2026-09-29 12:00'))
    expect(page.css('.case-file__list li').map(&:text)).
      to contain_exactly(a_string_including('Request sent'))
  end
end
