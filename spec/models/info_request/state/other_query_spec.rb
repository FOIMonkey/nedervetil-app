require 'spec_helper'

RSpec.describe InfoRequest::State::OtherQuery do
  describe '#call' do
    let(:info_request) do
      FactoryBot.create(:info_request_with_internal_review_request)
    end

    it 'includes those that are in internal review,
        and not waiting for description' do
      expect(described_class.new.call.include?(info_request)).to be true
    end

    it 'includes those that are under appeal' do
      under_appeal = FactoryBot.create(:info_request)
      under_appeal.set_described_state('under_appeal')
      expect(described_class.new.call).to include(under_appeal)
    end

    it 'excludes those that are waiting for description' do
      info_request.awaiting_description = true
      info_request.save!
      expect(described_class.new.call.include?(info_request)).
        to be false
    end
  end
end
