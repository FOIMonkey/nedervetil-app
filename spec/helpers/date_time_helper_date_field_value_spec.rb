require 'spec_helper'

RSpec.describe DateTimeHelper, '#date_field_value' do
  include DateTimeHelper

  it 'keeps an ISO date' do
    expect(date_field_value('2026-11-03')).to eq('2026-11-03')
  end

  it 'reads the year-first slashed dates an ISO locale’s addresses carry' do
    expect(date_field_value('2026/11/03')).to eq('2026-11-03')
  end

  it 'reads the day-first dates older search addresses carry' do
    expect(date_field_value('03/11/2026')).to eq('2026-11-03')
    expect(date_field_value('3/1/2001')).to eq('2001-01-03')
  end

  it 'gives nothing for what isn’t a date' do
    expect(date_field_value(nil)).to be_nil
    expect(date_field_value('')).to be_nil
    expect(date_field_value('soon')).to be_nil
    expect(date_field_value('31/02/2026')).to be_nil
    expect(date_field_value('2026-13-01')).to be_nil
  end
end
