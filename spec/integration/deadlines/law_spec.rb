require 'spec_helper'

RSpec.describe 'Deadlines and the law' do
  include_context 'with incoming attention off'
  let(:user) { FactoryBot.create(:user, trusted: true) }
  let(:start) { Time.zone.parse('2026-09-07 10:00') }

  def authority(tags = '')
    FactoryBot.create(:public_body, tag_string: tags)
  end

  def request_sent(at: start, tags: '', **attrs)
    travel_to(at) {
      FactoryBot.create(:info_request,
                        user: user,
                        public_body: authority(tags),
                        **attrs)
    }
  end

  def reply(request, at:, state:)
    travel_to(at) do
      message = FactoryBot.create(:incoming_message, info_request: request)
      request.log_event('response', incoming_message_id: message.id)
      request.reload.set_described_state(state)
      message
    end
  end

  def review_requested(request, at:)
    travel_to(at) {
      FactoryBot.create(:internal_review_request, info_request: request.reload)
    }
    request.reload
  end

  def action(request, on:)
    Deadlines::NextAction.for(request.reload, today: on.to_date)
  end

  describe 'the pages' do
    def page_for(request, path = "/request/#{request.url_title}", on: Date.new(2026, 10, 9))
      travel_to(on.in_time_zone.change(hour: 12)) do
        sign_in(user)
        get path
      end
      Nokogiri::HTML(response.body)
    end

    it 'sends a late Scottish request to a review, and a late English one to a reminder' do
      scottish = page_for(request_sent(tags: 'scotland'))
      expect(scottish.at_css('.next-step--act a.button').text).
        to eq('Ask for a review')
      expect(scottish.at_css('.next-step--act').text).
        to include('In Scotland the next step is a review: ask by 1 December')
      expect(scottish.text).not_to include('SIC', 'ICO')

      reset!
      english = page_for(request_sent)
      expect(english.at_css('.next-step--act .button').text).
        to eq('Remind them')
      expect(english.css('.next-step--act a').map(&:text)).
        to include('Complain to the ICO')
    end
  end
end
