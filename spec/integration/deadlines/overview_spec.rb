require 'spec_helper'

RSpec.describe Deadlines::Overview do
  include_context 'with incoming attention off' if defined?(IncomingAttention::Config)
  let(:user) { FactoryBot.create(:pro_user, trusted: true) }
  let(:start) { Time.zone.parse('2026-09-07 10:00') }
  let(:today) { Date.new(2026, 10, 1) }

  def request_sent(**attributes)
    request = travel_to(start) {
      FactoryBot.create(:info_request, user: user, **attributes)
    }
    if attributes[:date_response_required_by]
      request.update!(
        date_response_required_by: attributes[:date_response_required_by]
      )
    end
    request
  end

  def reply(request, state, at: start + 7.days)
    travel_to(at) do
      message = FactoryBot.create(:incoming_message, info_request: request)
      request.log_event('response', incoming_message_id: message.id)
      request.reload.set_described_state(state)
    end
  end

  def close(request)
    Deadlines::Closure.close!(
      request.reload,
      user: user,
      final_state: 'successful',
      last_event_id: request.info_request_events.maximum(:id)
    )
  end

  def signature(action)
    [action.request.id,
     action.kind,
     action.group,
     action.date,
     action.regime,
     action.adjustment&.id]
  end

  # The single-request calculation is the authority for the bulk result.
  def expect_current_actions
    ability = Ability.new(user)
    expected = user.info_requests.where.not(
      described_state: nil
    ).filter_map do |request|
      next unless ability.can?(:read, request)

      action = Deadlines::NextAction.for(request, today: today)
      signature(action) unless action.none?
    end
    actual = described_class.actions(user, today: today).map { |action|
                                       signature(action)
                                     }
    expect(actual).to match_array(expected)
  end

  describe 'dashboard rendering', feature: :alaveteli_pro do
    it 'puts each request in one pile, soonest first, five shown and the rest folded' do
      requests = Array.new(10) { |i|
        request_sent(date_response_required_by: today + 10 - i)
      }
      closed = request_sent
      reply(closed, 'successful')
      travel_to(start + 8.days) { close(closed) }
      travel_to(today.in_time_zone + 12.hours) {
        sign_in(user)
        get alaveteli_pro_dashboard_path
      }
      expect(response).to have_http_status(:ok)
      page = Nokogiri::HTML(response.body)
      waiting = page.at_css('[data-pile="waiting"]')
      expect(waiting.at_css('.request-section__count').text).to eq('10')
      expect(waiting.css('.pile__title').map(&:text)).
        to eq(requests.reverse.map(&:title))
      expect(waiting.xpath('./ul/li').size).to eq(5)
      expect(waiting.at_css('.pile__more summary').text).to eq('View 5 more')
      expect(page.at_css('[data-pile="finished"]').text).
        to include(closed.title, 'Marked complete')
      expect(page.css('.home-spots li').map { |tile| tile.text.squish }).
        to eq(['0 New replies',
               '0 Late',
               '10 Coming up Next ' \
               "#{Deadlines::Overview.format_date(today + 1)}"])
      expect(page.at_css('[data-pile="needs"]')).to be_nil
    end

    context 'with replies to read' do
      include_context 'with lean attention predictions' if defined?(IncomingAttention::Config)
      before { skip 'IncomingAttention arrives in B10' unless defined?(IncomingAttention::Config) }
      # Coming up, late (one reminded for its date, one reminded recently for
      # an earlier date), a reply to read and finished: each kind of row Home
      # shows.
      def rows_of_each_kind(count)
        count.times do
          request_sent(date_response_required_by: today + 5)
          request_sent(date_response_required_by: today - 5)
          unread = request_sent(date_response_required_by: today + 5)
          travel_to(start + 3.days) { lean_response(unread, 'REVIEW') }
          reply(request_sent, 'successful')
        end
        reminded, recent = Array.new(2) {
          request_sent(date_response_required_by: today - 3)
        }
        travel_to(today - 2) do
          Deadlines::Reminder.create!(info_request: reminded,
                                      user: user,
                                      stage: 'response',
                                      due_on: today - 3)
          Deadlines::Reminder.create!(info_request: recent,
                                      user: user,
                                      stage: 'response',
                                      due_on: today - 10)
        end
      end

      def page(path)
        travel_to(today.in_time_zone + 12.hours) do
          sign_in(user)
          get path
        end
        expect(response).to have_http_status(:ok)
        response.body.gsub(
          # rubocop:disable Layout/LineLength
          /(name="authenticity_token" value|name="csrf-token" content|name="csp-nonce" content|nonce)="[^"]*"/,
          # rubocop:enable Layout/LineLength
          '\1=""'
        )
      end

      def statements(path)
        count = 0
        counter = ->(*, payload) {
          unless payload[:cached] ||
                 %w[SCHEMA TRANSACTION].include?(payload[:name])
            count += 1
          end
        }
        ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { page(path) }
        count
      end

      it 'runs as many statements for many rows as for a few, on Home and the request list' do
        rows_of_each_kind(2)
        sign_in(user)
        statements(alaveteli_pro_dashboard_path)
        few = [statements(alaveteli_pro_dashboard_path),
               statements(alaveteli_pro_info_requests_path)]
        rows_of_each_kind(4)
        many = [statements(alaveteli_pro_dashboard_path),
                statements(alaveteli_pro_info_requests_path)]

        expect(Nokogiri::HTML(response.body).css('li.pile__row').size).to eq(28)
        expect(many.zip(few).map { |large, small| large - small }).
          to all(be <= 2)
      end

      it 'shows the same rows with each pile loaded at once as one row at a time' do
        rows_of_each_kind(2)
        sign_in(user)
        paths = [alaveteli_pro_dashboard_path, alaveteli_pro_info_requests_path]
        together = paths.map { |path| page(path) }
        allow(Deadlines::Piles::Batch).to receive(:for).and_return(nil)
        one_by_one = paths.map { |path| page(path) }

        expect(together).to eq(one_by_one)
        reasons = Nokogiri::HTML(together.first).css(
          '[data-pile="needs"] .pile__reason'
        ).map(&:text)
        expect(reasons.count { |reason| reason.include?('reminded') }).to eq(2)
      end

      it 'takes a request whose new replies are routine as waiting, without checking it again' do
        routine = Array.new(3) {
          request_sent(date_response_required_by: today + 5)
        }
        routine.
          each { |request|
            travel_to(start + 3.days) {
              lean_response(request, 'SKIP')
            }
          }
        sign_in(user)
        allow(IncomingAttention::Effective).
          to receive(:dashboard_status).and_call_original
        waiting = Nokogiri::HTML(page(alaveteli_pro_dashboard_path)).css(
          '[data-pile="waiting"] [data-request-id]'
        )

        expect(waiting.map { |row| row['data-request-id'].to_i }).
          to match_array(routine.map(&:id))
        expect(IncomingAttention::Effective).
          not_to have_received(:dashboard_status)
      end
    end
  end
end
