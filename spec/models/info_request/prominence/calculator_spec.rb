require 'spec_helper'

RSpec.describe InfoRequest::Prominence::Calculator do
  let(:info_request) { FactoryBot.build(:info_request) }

  def expect_value(prominence, method, value)
    info_request.prominence = prominence
    expect(described_class.new(info_request).send(method)).to eq(value)
  end

  describe '#is_requester_only?' do
    it 'returns false if its prominence is hidden' do
      expect_value('hidden', :is_requester_only?, false)
    end

    it 'returns true if its prominence is requester_only' do
      expect_value('requester_only', :is_requester_only?, true)
    end
  end
end
