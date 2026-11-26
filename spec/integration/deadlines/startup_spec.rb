require 'spec_helper'
require 'open3'

RSpec.describe 'Deadline configuration at startup' do
  let(:boot_script) do
    "require './config/environment'; puts 'Application booted'"
  end

  def boot_with(calendar)
    Open3.capture3(
      { 'RAILS_ENV' => 'test',
        'ALAVETELI_WORKING_OR_CALENDAR_DAYS' => calendar },
      RbConfig.ruby, '-e', boot_script, chdir: Rails.root
    )
  end

  it 'starts with the supported working-day configuration' do
    stdout, stderr, status = boot_with('working')

    expect(status.success?).to eq(true), stderr
    expect(stdout).to include('Application booted')
  end

  it 'refuses to start with calendar days configured' do
    stdout, stderr, status = boot_with('calendar')

    expect(status.success?).to eq(false)
    expect(stdout).not_to include('Application booted')
    expect(stderr).to include(
      'Deadlines::Calendar::UnsupportedCalendar',
      'Request deadlines require WORKING_OR_CALENDAR_DAYS: working'
    )
  end
end
