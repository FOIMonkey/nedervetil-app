require 'spec_helper'

# Expected dates were worked out separately from the gov.uk bank holidays.
RSpec.describe 'Deadlines and the law' do
  include_context 'with incoming attention off' if defined?(IncomingAttention::Config)
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

  describe 'regimes' do
    it 'tells the four laws apart, finding Scotland by either tag' do
      expect(Deadlines.regime(request_sent)).to eq('foi')
      expect(Deadlines.regime(request_sent(law_used: 'eir'))).to eq('eir')
      expect(Deadlines.regime(request_sent(tags: 'scotland'))).to eq('foisa')
      expect(Deadlines.regime(request_sent(tags: 'sic:S12000049'))).
        to eq('foisa')
      expect(Deadlines.regime(request_sent(tags: 'scotland', law_used: 'eir'))).
        to eq('eisr')
      expect(action(request_sent(tags: 'scotland', law_used: 'eir'),
                    on: start).law).to eq('EIR (Scotland)')
    end
  end

  describe Deadlines::Calendar do
    it 'skips bank holidays in any part of the UK for FOI, and only Scotland\'s for FOISA' do
      uk_only = [Date.new(2026, 3, 17),
                 Date.new(2026, 4, 6),
                 Date.new(2026, 7, 13),
                 Date.new(2026, 8, 31)]
      scottish = [Date.new(2026, 6, 15), Date.new(2026,
                                                  8,
                                                  3), Date.new(2026, 11, 30)]
      uk_only.each do |day|
        expect(described_class.working_day?(day, 'foi')).to eq(false)
        expect(described_class.working_day?(day, 'foisa')).to eq(true)
      end
      scottish.each do |day|
        expect(described_class.working_day?(day, 'foi')).to eq(false)
        expect(described_class.working_day?(day, 'eisr')).to eq(false)
      end
    end

    def walked(from, to, regime)
      if to > from
        ((from + 1)..to).count { |day|
          described_class.working_day?(day, regime)
        }
      else
        0
      end
    end

    it 'counts the same working days as walking them, for every law, around holidays, weekends and the end of the data' do
      last = Deadlines::BankHolidays.last_day
      # After the gov.uk data, core's own table is the only source.
      core = [Date.new(2025, 12, 25),
              Date.new(2026, 8, 31),
              last + 6,
              last + 7,
              last + 96,
              Date.new(2030, 5, 6)]
      allow(Holiday).to receive(:holidays).and_return(core)
      holidays = (Deadlines::BankHolidays.uk |
                  Deadlines::BankHolidays.scotland | core).to_a
      spans = [0, 1, 2, 5, 9]
      pairs = holidays.flat_map { |day|
        (-3..3).flat_map { |shift|
          spans.map { |span| [day + shift, day + shift + span] }
        }
      }
      pairs += (-15..15).flat_map { |shift|
        [[last + shift, last + shift + 3], [last + shift, last + shift + 40]]
      }
      random = Random.new(20261025)
      pairs += Array.new(400) {
        from = Date.new(2015, 1, 1) + random.rand(5800)
        [from, from + random.rand(-10..400)]
      }

      [nil, 'foi', 'eir', 'foisa', 'eisr'].each do |regime|
        wrong = pairs.reject { |from, to|
          described_class.working_days_between(
            from,
            to,
            regime
          ) == walked(from, to, regime)
        }
        expect(wrong).
          to be_empty, "#{regime.inspect}: #{wrong.first(5).inspect}"
      end
    end

    it 'counts a request two years late without walking its days, once' do
      today = Date.new(2026, 10, 30)
      request = request_sent(at: Time.zone.parse('2024-01-08 10:00'))
      late = action(request, on: today)
      described_class.working_days_between(Date.new(2024, 1, 1),
                                           Date.new(2024, 1, 2),
                                           late.regime)
      before = GC.stat(:total_allocated_objects)
      days = late.late_days
      allocated = GC.stat(:total_allocated_objects) - before

      expect(days).to be > 600
      expect(days).to eq(walked(late.date, today, late.regime))
      expect(allocated).to be < 300

      again = action(request, on: today)
      allow(described_class).to receive(:working_days_late).and_call_original
      3.times { again.late_days }
      expect(described_class).to have_received(:working_days_late).once
    end

    it 'sets core\'s due date on the request\'s own calendar' do
      sent = Time.zone.parse('2026-03-09 10:00')
      expect(request_sent(at: sent).date_response_required_by).
        to eq(Date.new(2026, 4, 9))
      expect(request_sent(at: sent,
                          tags: 'scotland').date_response_required_by).
        to eq(Date.new(2026, 4, 7))
    end
  end

  describe 'review windows' do
    it 'counts the FOISA window from the due date when the reply came early, and EIR(S) from the reply' do
      foisa = request_sent(tags: 'scotland')
      reply(foisa, at: Time.zone.parse('2026-09-14 10:00'), state: 'rejected')
      expect(action(foisa, on: Date.new(2026, 9, 15))).
        to have_attributes(kind: :ask_review, date: Date.new(2026, 12, 1))

      eisr = request_sent(tags: 'scotland', law_used: 'eir')
      reply(eisr, at: Time.zone.parse('2026-09-14 10:00'), state: 'rejected')
      expect(action(eisr, on: Date.new(2026, 9, 15)).date).
        to eq(Date.new(2026, 11, 9))
    end

    it 'gives the authority 20 working days for a Scottish review and 40 for an English EIR one' do
      eisr = request_sent(tags: 'scotland', law_used: 'eir')
      reply(eisr, at: start + 7.days, state: 'rejected')
      review_requested(eisr, at: Time.zone.parse('2026-09-21 10:00'))
      expect(action(eisr, on: Date.new(2026, 9, 22)).date).
        to eq(Date.new(2026, 10, 19))

      eir = request_sent(law_used: 'eir')
      reply(eir, at: start + 7.days, state: 'rejected')
      review_requested(eir, at: Time.zone.parse('2026-09-21 10:00'))
      expect(action(eir, on: Date.new(2026, 9, 22)).date).
        to eq(Date.new(2026, 11, 16))
    end
  end

  describe 'when the authority is late' do
    it 'offers a review of the silence in Scotland and under the EIR, not under FOI' do
      expect(action(request_sent(tags: 'scotland'),
                    on: Date.new(2026,
                                 10,
                                 9)).review_by).to eq(Date.new(2026, 12, 1))
      expect(action(request_sent(law_used: 'eir'),
                    on: Date.new(2026,
                                 10,
                                 9)).review_by).to eq(Date.new(2026, 12, 1))
      expect(action(request_sent, on: Date.new(2026, 10, 9)).review_by).
        to be_nil
    end

    it 'gives six months from an unanswered review in Scotland, and none elsewhere' do
      scottish = request_sent(tags: 'scotland')
      reply(scottish, at: start + 7.days, state: 'rejected')
      review_requested(scottish, at: Time.zone.parse('2026-09-21 10:00'))
      late = action(scottish, on: Date.new(2026, 10, 26))
      expect(late).
        to have_attributes(kind: :review,
                           late?: true,
                           regulator_by: Date.new(2027, 4, 19))
      expect(late.timeline.last).
        to eq(['Apply to the Commissioner by', Date.new(2027, 4, 19)])

      english = request_sent
      reply(english, at: start + 7.days, state: 'rejected')
      review_requested(english, at: Time.zone.parse('2026-09-21 10:00'))
      expect(action(english, on: Date.new(2026, 10, 26)).regulator_by).to be_nil
    end
  end

  describe 'clarification' do
    it 'shows how long the requester has to answer: two months, or 40 working days in Scotland' do
      english = request_sent
      reply(english, at: Time.zone.parse('2026-09-10 10:00'),
                     state: 'waiting_clarification')
      expect(action(english, on: Date.new(2026, 9, 11)).reply_by).
        to eq(Date.new(2026, 11, 10))

      scottish = request_sent(tags: 'scotland')
      reply(scottish, at: Time.zone.parse('2026-09-10 10:00'),
                      state: 'waiting_clarification')
      expect(action(scottish, on: Date.new(2026, 9, 11)).reply_by).
        to eq(Date.new(2026, 11, 5))
    end
  end

  describe 'extensions' do
    def extend!(request, reason, due_on)
      travel_to(Time.zone.parse('2026-09-21 10:00')) do
        Deadlines::Adjustment.apply!(request, stage: 'response',
                                              user: user,
                                              due_on: due_on,
                                              reason: reason)
      end
    end

    it 'allows only the extensions each law has' do
      expect {
        extend!(request_sent(tags: 'scotland'),
                'public_interest',
                Date.new(2026, 10, 30))
      }.to raise_error(ActiveRecord::RecordInvalid)
      expect {
        extend!(request_sent(tags: 'scotland'),
                'eir_extension',
                Date.new(2026, 10, 30))
      }.to raise_error(ActiveRecord::RecordInvalid)
      expect { extend!(request_sent, 'eir_extension', Date.new(2026, 10, 30)) }.
        to raise_error(ActiveRecord::RecordInvalid)
      expect(extend!(request_sent(tags: 'scotland'),
                     'agreed',
                     Date.new(2026, 10, 30))).to be_persisted
      expect(extend!(request_sent, 'public_interest', Date.new(2026, 10, 30))).
        to be_persisted
    end

    it 'caps an EIR extension at 40 working days and never moves a date earlier than the law' do
      expect(extend!(request_sent(law_used: 'eir'),
                     'eir_extension',
                     Date.new(2026, 11, 2))).to be_persisted
      expect {
        extend!(request_sent(law_used: 'eir'),
                'eir_extension',
                Date.new(2026, 11, 3))
      }.to raise_error(ActiveRecord::RecordInvalid, /40 working days/)
      expect { extend!(request_sent, 'agreed', Date.new(2026, 10, 1)) }.
        to raise_error(ActiveRecord::RecordInvalid,
                       /earlier than the date the law gives/)
    end

    it 'keeps the day-20 refusal notice date under a public interest extension' do
      request = request_sent
      extend!(request, 'public_interest', Date.new(2026, 10, 30))
      expect(action(request,
                    on: Date.new(2026, 9, 22)).timeline.map(&:first).first(3)).
        to eq(['Request sent', 'Refusal notice due', 'Response due'])
    end
  end
end
