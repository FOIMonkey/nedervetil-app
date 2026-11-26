require 'spec_helper'

RSpec.describe InfoRequest::ExpireJob, type: :job do
  let(:args) { [] }
  subject(:perform) { described_class.new.perform(*args) }

  let(:request_1) { FactoryBot.build(:info_request) }
  let(:request_2) { FactoryBot.build(:info_request) }

  context 'when called with a request' do
    let(:args) { [request_1] }

    it 'calls expire on the request' do
      expect(request_1).to receive(:expire)
      perform
    end
  end

  context 'when called with an object with a info_requests association' do
    let(:user) do
      FactoryBot.build(:user, info_requests: [request_1, request_2])
    end

    let(:args) { [user, :info_requests] }

    it 'calls expire on the associated requests' do
      association = double(klass: InfoRequest)
      allow(user).to receive(:association).with(:info_requests).
        and_return(association)
      allow(association).to receive_message_chain(:reader, :find_each).
        and_yield(request_1).and_yield(request_2)

      expect(request_1).to receive(:expire)
      expect(request_2).to receive(:expire)
      perform
    end
  end

  context 'when called with the InfoRequest class' do
    let(:args) { [InfoRequest, :all] }

    it 'calls expire on the all requests' do
      allow(InfoRequest).to receive_message_chain(:all, :find_each).
        and_yield(request_1).and_yield(request_2)

      expect(request_1).to receive(:expire)
      expect(request_2).to receive(:expire)
      perform
    end
  end

  describe 'storing the text of the replies again' do
    include ActiveJob::TestHelper

    let(:info_request) { FactoryBot.create(:info_request) }

    it 'is queued for what was expired, once it has been expired' do
      expired = false
      allow(info_request).to receive(:expire) { expired = true }
      allow(InfoRequest::StoreReplyTextJob).
        to receive(:perform_later) { expect(expired).to be true }

      described_class.new.perform(info_request)

      expect(InfoRequest::StoreReplyTextJob).
        to have_received(:perform_later).with(info_request)
    end

    it 'is queued once for a sweep of many requests' do
      user = FactoryBot.create(:user)
      FactoryBot.create_list(:info_request, 2, user: user)

      expect { described_class.new.perform(user, :info_requests) }.
        to have_enqueued_job(InfoRequest::StoreReplyTextJob).with(user).once
    end

    it 'is queued for every request after a sweep of them all' do
      allow(InfoRequest).to receive_message_chain(:all, :find_each)

      expect { described_class.new.perform(InfoRequest, :all) }.
        to have_enqueued_job(InfoRequest::StoreReplyTextJob).
        with(InfoRequest).once
    end

    it 'never stops the expiry when it cannot be queued' do
      allow(InfoRequest::StoreReplyTextJob).to receive(:perform_later).
        and_raise(RedisClient::CannotConnectError)
      expect(info_request).to receive(:expire)

      expect { described_class.new.perform(info_request) }.not_to raise_error
    end
  end
end
