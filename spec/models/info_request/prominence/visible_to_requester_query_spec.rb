require 'spec_helper'

RSpec.describe InfoRequest::Prominence::VisibleToRequesterQuery do
  describe '#call' do
    it 'returns requester_only requests, not hidden ones' do
      requester_only_request =
        FactoryBot.create(:info_request, prominence: 'requester_only')
      hidden_request = FactoryBot.create(:info_request, prominence: 'hidden')
      requests = described_class.new.call
      expect(requests).to include(requester_only_request)
      expect(requests).not_to include(hidden_request)
    end
  end
end
