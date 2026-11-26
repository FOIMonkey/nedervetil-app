require 'spec_helper'

# Core's query in InfoRequest.log_overdue_event_type raises once a request has
# two overdue events after its date, and then logs nothing for anyone.
RSpec.describe 'Overdue events after a restored due date' do
  include_context 'with incoming attention off' if defined?(IncomingAttention::Config)
  # Monday 7 September 2026: the response is due on 5 October.
  let(:start) { Time.zone.parse('2026-09-07 10:00') }
  let(:user) { FactoryBot.create(:user, trusted: true) }

  def request_sent(at: start)
    travel_to(at) { FactoryBot.create(:info_request, user: user) }
  end

  def on(date, &block)
    travel_to(Time.zone.parse("#{date} 10:00"), &block)
  end

  def extend_to(request, due_on)
    Deadlines::Adjustment.apply!(request.reload, stage: 'response', user: user,
                                                 due_on: due_on,
                                                 reason: 'public_interest')
  end

  def events(request, type = 'overdue')
    request.info_request_events.where(event_type: type)
  end

  def daily_run
    InfoRequest.log_overdue_events
    InfoRequest.log_very_overdue_events
  end

  def expect_other_logged_once(other)
    on(other.reload.date_response_required_by + 1) do
      expect { daily_run }.not_to raise_error
    end
    logged = events(other)
    expect(logged.count).to eq(1)
    expect(Notification.where(info_request_event_id: logged.select(:id)).count).
      to eq(1)
  end

  let!(:request) { request_sent }
  let!(:other) { request_sent(at: start + 22.days) }

  it 'keeps logging for everyone after a passed extension is restored' do
    on('2026-10-06') { InfoRequest.log_overdue_events }
    on('2026-10-07') { extend_to(request, Date.new(2026, 10, 20)) }
    on('2026-10-21') { InfoRequest.log_overdue_events }
    on('2026-10-22') { Deadlines::Adjustment.clear!(request.reload, 'response') }
    expect(request.reload.date_response_required_by).
      to eq(Date.new(2026, 10, 5))

    expect_other_logged_once(other)
    expect(events(request).count).to eq(2)
  end

  it 'keeps logging for everyone after the original date is entered again' do
    on('2026-10-06') { InfoRequest.log_overdue_events }
    on('2026-10-07') { extend_to(request, Date.new(2026, 10, 20)) }
    on('2026-10-21') { InfoRequest.log_overdue_events }
    on('2026-10-22') { extend_to(request, Date.new(2026, 10, 5)) }
    expect(request.reload.date_response_required_by).
      to eq(Date.new(2026, 10, 5))

    expect_other_logged_once(other)
    expect(events(request).count).to eq(2)
  end

  it 'keeps logging for everyone after an extension to a date already passed is restored' do
    on('2026-10-06') { InfoRequest.log_overdue_events }
    on('2026-10-07') { extend_to(request, Date.new(2026, 10, 6)) }
    on('2026-10-08') { InfoRequest.log_overdue_events }
    expect(events(request).count).to eq(2)
    on('2026-10-09') { Deadlines::Adjustment.clear!(request.reload, 'response') }

    expect_other_logged_once(other)
    expect(events(request).count).to eq(2)
  end

  it 'logs the same requests in the same order as core’s query where that does not raise' do
    extended = request_sent(at: start + 1.day)
    on('2026-10-06') { InfoRequest.log_overdue_events }
    on('2026-10-07') { extend_to(extended, Date.new(2026, 10, 20)) }
    expect(InfoRequest.method(:log_overdue_event_type).owner).
      to eq(InfoRequest.singleton_class)
    # Core's own pass, with its scalar subquery.
    core = ->(event_type) do
      date_field = if event_type == 'overdue'
                     'date_response_required_by'
                   else
                     'date_very_overdue_after'
                   end
      InfoRequest.where(["awaiting_description = ?
              AND described_state = ?
              AND #{date_field} < ?
              AND (SELECT id
              FROM info_request_events
              WHERE info_request_id = info_requests.id
              AND event_type = ?
              AND created_at > info_requests.#{date_field})
              IS NULL",
                         false,
                         'waiting_response',
                         Time.zone.today,
                         event_type]).
        find_each(batch_size: 100) do |info_request|
          created_at = info_request.send(date_field).beginning_of_day + 1.day
          event = info_request.log_event(event_type,
                                         { event_created_at: Time.zone.now },
                                         created_at: created_at)
          info_request.user.notify(event) if info_request.use_notifications?
        end
    end

    logged = ->(&run) do
      ids = []
      allow_any_instance_of(InfoRequest).
        to receive(:log_event).and_wrap_original do |original, *args, **options|
        ids << original.receiver.id
        original.call(*args, **options)
      end
      ActiveRecord::Base.transaction(requires_new: true) do
        run.call
        raise ActiveRecord::Rollback
      end
      ids
    end

    on('2026-12-01') do
      %w[overdue very_overdue].each do |type|
        ours = logged.call { InfoRequest.log_overdue_event_type(type) }
        expect(ours).to include(other.id) if type == 'overdue'
        expect(ours).to eq(logged.call { core.call(type) })
      end
    end
  end

  it 'keeps logging very overdue events after a very overdue request is restored' do
    very = request.date_very_overdue_after
    on(very + 1) { daily_run }
    expect(events(request, 'very_overdue').count).to eq(1)

    on(very + 2) { extend_to(request, very + 8) }
    later_very = request.reload.date_very_overdue_after
    on(very + 9) { daily_run }
    on(later_very + 1) { daily_run }
    expect(events(request, 'very_overdue').count).to eq(2)
    on(later_very + 2) { Deadlines::Adjustment.clear!(request.reload, 'response') }
    expect(request.reload.date_very_overdue_after).to eq(very)

    late = request_sent(at: Time.zone.parse((later_very + 3).to_s))
    on(late.date_very_overdue_after + 1) do
      expect { InfoRequest.log_very_overdue_events }.not_to raise_error
      expect { InfoRequest.log_overdue_events }.not_to raise_error
    end
    expect(events(late, 'very_overdue').count).to eq(1)
    expect(events(request, 'very_overdue').count).to eq(2)
    expect(events(request).count).to eq(2)
  end
end
