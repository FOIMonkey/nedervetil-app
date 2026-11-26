require 'spec_helper'

RSpec.describe Deadlines::Checker do
  let(:days) { AlaveteliConfiguration.reply_late_after_days }

  it 'counts as request deadlines do' do
    checker = described_class.new('2026-03-02', 'uk')
    expect(checker.due).to eq(
      Deadlines::Calendar.working_days_after(Date.new(2026, 3, 2), days, 'foi')
    )
    expect(checker).to be_known
    expect(checker).not_to be_scottish
  end

  it 'counts Scotland’s own bank holidays for an authority there' do
    scottish = described_class.new('2026-03-20', 'scotland')
    expect(scottish).to be_scottish
    expect(scottish.due).to eq(
      Deadlines::Calendar.
        working_days_after(Date.new(2026, 3, 20), days, 'foisa')
    )
    # Easter Monday is a bank holiday in England and Wales, not Scotland.
    expect(scottish.due).to be < described_class.new('2026-03-20', 'uk').due
  end

  it 'has no answer until a date is given, or for one that isn’t a date' do
    expect(described_class.new(nil)).not_to be_asked
    expect(described_class.new(nil).due).to be_nil

    ['', 'tomorrow', '2026-02-31', '20260302', '2026-3-2'].each do |typed|
      checker = described_class.new(typed)
      expect(checker).to be_asked
      expect(checker.received).to be_nil, typed
      expect(checker).not_to be_known
    end
  end

  it 'doesn’t answer outside the years its bank holidays cover' do
    expect(described_class.new('2023-06-01')).not_to be_known
    expect(described_class.new('2027-12-20')).not_to be_known
    expect(described_class.new('2027-06-01')).to be_known
  end

  context 'with no bank holiday data' do
    before do
      allow(Deadlines::BankHolidays).to receive_messages(
        uk: Set.new, scotland: Set.new, last_day: Date.new(0)
      )
    end

    it 'counts on core’s holidays alone, with one calendar for everywhere' do
      expect(described_class.scotland?).to be(false)
      checker = described_class.new('2031-06-02', 'scotland')
      expect(checker).not_to be_scottish
      expect(checker).to be_known
      expect(checker.due).to eq(
        Deadlines::Calendar.working_days_after(Date.new(2031, 6, 2), days)
      )
    end
  end
end
