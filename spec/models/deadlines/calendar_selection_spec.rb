require 'spec_helper'

RSpec.describe 'Request deadline calendar selection' do
  let(:due_on) { Date.new(2026, 10, 5) }
  let(:request) do
    FactoryBot.build(:info_request,
                    date_initial_request_last_sent_at: Date.new(2026, 9, 7))
  end

  # The release configuration leaves this at the core default. Assert the
  # default as well as exercising it, so a future default change is reviewed.
  before do
    allow(AlaveteliConfiguration).to receive(:working_or_calendar_days).
      and_return(AlaveteliConfiguration::DEFAULTS.fetch(:WORKING_OR_CALENDAR_DAYS))
  end

  it 'uses working days by default' do
    expect(AlaveteliConfiguration.working_or_calendar_days).to eq('working')
  end

  it 'calculates the response deadline with the request calendar' do
    expect(Holiday).not_to receive(:due_date_from)
    expect(Deadlines::Calendar).to receive(:working_days_after).
      with(Date.new(2026, 9, 7), 20, 'foi').and_call_original

    expect(request.calculate_date_response_required_by).
      to eq(Date.new(2026, 10, 5))
  end

  it 'calculates the very overdue date with the request calendar' do
    expect(Holiday).not_to receive(:due_date_from)
    expect(Deadlines::Calendar).to receive(:working_days_after).
      with(Date.new(2026, 9, 7), 40, 'foi').and_call_original

    expect(request.calculate_date_very_overdue_after).
      to eq(Date.new(2026, 11, 2))
  end

  it 'uses the same calendar for an adjusted very overdue date' do
    expect(Holiday).not_to receive(:due_date_from)
    expect(Deadlines::Calendar).to receive(:working_days_after).
      with(Date.new(2026, 10, 5), 20, 'foi').and_call_original

    expect(Deadlines::Adjustment.very_overdue_after(request, due_on)).
      to eq(Date.new(2026, 11, 2))
  end

  it 'calculates legacy request dates when the stored dates are NULL' do
    expect(request[:date_response_required_by]).to be_nil
    expect(request[:date_very_overdue_after]).to be_nil
    expect(request.date_response_required_by).to eq(Date.new(2026, 10, 5))
    expect(request.date_very_overdue_after).to eq(Date.new(2026, 11, 2))
  end

  it 'keeps guarding NULL-date readers if configuration changes after boot' do
    allow(AlaveteliConfiguration).to receive(:working_or_calendar_days).
      and_return('calendar')

    expect { request.date_response_required_by }.
      to raise_error(Deadlines::Calendar::UnsupportedCalendar)
    expect { request.date_very_overdue_after }.
      to raise_error(Deadlines::Calendar::UnsupportedCalendar)
  end

  ['calendar', nil, 'unknown'].each do |mode|
    context "with unsupported calendar setting #{mode.inspect}" do
      before do
        allow(AlaveteliConfiguration).to receive(:working_or_calendar_days).
          and_return(mode)
        expect(Holiday).not_to receive(:due_date_from)
        expect(Deadlines::Calendar).not_to receive(:working_days_after)
      end

      it 'refuses to calculate the response deadline' do
        expect { request.calculate_date_response_required_by }.
          to raise_error(Deadlines::Calendar::UnsupportedCalendar,
                         /WORKING_OR_CALENDAR_DAYS: working/)
      end

      it 'refuses to calculate the very overdue date' do
        expect { request.calculate_date_very_overdue_after }.
          to raise_error(Deadlines::Calendar::UnsupportedCalendar)
      end

      it 'refuses to calculate an adjusted very overdue date' do
        expect {
          Deadlines::Adjustment.very_overdue_after(request, due_on)
        }.to raise_error(Deadlines::Calendar::UnsupportedCalendar)
      end
    end
  end
end
