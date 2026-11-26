require 'spec_helper'

RSpec.describe Deadlines::Clearable do
  let(:request) { FactoryBot.create(:info_request) }
  let(:basis_event_id) { request.info_request_events.first.id }

  def adjustment(stage, cleared: false)
    record = Deadlines::Adjustment.new(
      info_request: request, stage: stage, basis_event_id: basis_event_id,
      due_on: Time.zone.today, original_due_on: Time.zone.today,
      reason: 'other', cleared_at: (Time.current if cleared)
    )
    record.save!(validate: false)
    record
  end

  def closure(cleared: false)
    record = Deadlines::Closure.new(
      info_request: request, basis_event_id: basis_event_id,
      final_state: 'successful', cleared_at: (Time.current if cleared)
    )
    record.save!(validate: false)
    record
  end

  def queries
    count = 0
    callback = ->(*, payload) { count += 1 unless payload[:name] == 'SCHEMA' }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      yield
    end
    count
  end

  describe '.latest_active' do
    it 'gives the newest record not cleared that meets the conditions' do
      adjustment('response')
      newest = adjustment('response')
      adjustment('response', cleared: true)
      adjustment('review')

      expect(Deadlines::Adjustment.latest_active(request, stage: 'response')).
        to eq(newest)
    end

    it 'gives the same from a preloaded list, without a query' do
      adjustment('response')
      newest = adjustment('response')
      adjustment('response', cleared: true)
      loaded = InfoRequest.includes(:deadline_adjustments).find(request.id)

      found = nil
      expect(queries {
        found = Deadlines::Adjustment.latest_active(loaded, stage: 'response')
      }).to eq(0)
      expect(found).to eq(newest)
    end

    it 'works with no conditions, for closures' do
      kept = closure
      closure(cleared: true)

      expect(Deadlines::Closure.latest_active(request)).to eq(kept)
      loaded = InfoRequest.includes(:deadline_closures).find(request.id)
      expect(Deadlines::Closure.latest_active(loaded)).to eq(kept)
    end

    it 'is nil when everything is cleared' do
      adjustment('response', cleared: true)
      expect(Deadlines::Adjustment.latest_active(request, stage: 'response')).
        to be_nil
    end
  end

  describe '.clear_active!' do
    it 'clears only the records that meet the conditions' do
      response = adjustment('response')
      review = adjustment('review')

      Deadlines::Adjustment.clear_active!(request, stage: 'response')

      expect(response.reload).not_to be_active
      expect(review.reload).to be_active
    end
  end
end
