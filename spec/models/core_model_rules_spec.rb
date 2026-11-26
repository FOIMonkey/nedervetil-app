require 'spec_helper'

RSpec.describe 'Rules the app adds to core models' do
  describe InfoRequest do
    it 'is created as requester_only by default' do
      info_request = FactoryBot.create(:info_request)
      expect(info_request.reload.prominence).to eq('requester_only')
    end

    it 'leaves an explicit hidden alone' do
      info_request = FactoryBot.create(:info_request, prominence: 'hidden')
      expect(info_request.reload.prominence).to eq('hidden')
    end

    # Nothing is public: upstream's public prominences are refused.
    %w[normal backpage].each do |prominence|
      it "refuses #{prominence}, when created or changed later" do
        expect(FactoryBot.build(:info_request, prominence: prominence)).
          not_to be_valid
        info_request = FactoryBot.create(:info_request)
        expect { info_request.update!(prominence: prominence) }.
          to raise_error(ActiveRecord::RecordInvalid)
        expect(info_request.reload.prominence).to eq('requester_only')
      end
    end

    it 'can be read by the requester but not by other users or guests' do
      info_request = FactoryBot.create(:info_request)
      other_user = FactoryBot.create(:user)

      expect(Ability.new(info_request.user).can?(:read, info_request)).
        to eq(true)
      expect(Ability.new(other_user).can?(:read, info_request)).to eq(false)
      expect(Ability.new(nil).can?(:read, info_request)).to eq(false)
    end
  end

  describe IncomingMessage do
    it 'keeps core\'s normal prominence, so core answers and replies to it' do
      incoming_message = FactoryBot.create(:incoming_message)
      incoming_message.info_request.
        log_event('response', incoming_message_id: incoming_message.id)
      expect(incoming_message.reload.prominence).to eq('normal')
      expect(incoming_message.info_request.reload.last_public_response).
        to eq(incoming_message)
    end

    it 'leaves an explicit hidden alone' do
      incoming_message =
        FactoryBot.create(:incoming_message, prominence: 'hidden')
      expect(incoming_message.reload.prominence).to eq('hidden')
    end

    it 'stays private through its request: only the requester can read it' do
      incoming_message = FactoryBot.create(:incoming_message)
      request = incoming_message.info_request
      expect(request.reload.prominence).to eq('requester_only')
      expect(Ability.new(request.user).can?(:read, incoming_message)).
        to eq(true)
      expect(Ability.new(FactoryBot.create(:user)).
               can?(:read, incoming_message)).to eq(false)
      expect(Ability.guest.can?(:read, incoming_message)).to eq(false)
    end
  end

  describe 'the internal review letter' do
    it 'leaves out the link to the request\'s page' do
      request = FactoryBot.create(:info_request)
      letter = OutgoingMessage.new(info_request: request,
                                   message_type: 'followup',
                                   what_doing: 'internal_review').
        default_message
      expect(letter).to include('request an internal review')
      expect(letter).
        not_to include('available on the Internet', request.url_title)
    end
  end

  describe 'a request that produced no information' do
    let(:info_request) { FactoryBot.create(:info_request) }

    it 'is stored as refused when it is classified as not held' do
      info_request.set_described_state('not_held')

      expect(info_request.reload.described_state).to eq('rejected')
      expect(info_request.info_request_events.last.described_state).
        to eq('rejected')
    end

    it 'leaves other states alone' do
      info_request.set_described_state('partially_successful')
      expect(info_request.reload.described_state).to eq('partially_successful')
    end

    it 'offers the owner one "no information" option, not two' do
      complete = InfoRequest::State::Calculator.new(info_request).
        transitions(is_owning_user: true,
                    user_asked_to_update_status: true)[:complete]

      expect(complete.keys).
        to match_array(%w[partially_successful successful rejected])
    end
  end

  describe 'a reply delivered through Action Mailbox' do
    let(:info_request) { FactoryBot.create(:info_request) }

    it 'arrives on the right request, private through the request' do
      expect {
        receive_incoming_mail('incoming-request-plain.eml',
                              to: info_request.incoming_email)
      }.to change { info_request.incoming_messages.count }.from(0).to(1)

      incoming_message = info_request.incoming_messages.last
      expect(incoming_message.prominence).to eq('normal')
      expect(info_request.reload.prominence).to eq('requester_only')
      expect(Ability.guest.can?(:read, incoming_message)).to eq(false)
    end

    it 'leaves the holding pen request hidden' do
      receive_incoming_mail('incoming-request-plain.eml',
                            to: 'nobody-in-particular@localhost')

      holding_pen = InfoRequest.holding_pen_request
      expect(holding_pen.prominence).to eq('hidden')
      expect(Ability.guest.can?(:read, holding_pen.incoming_messages.last)).
        to eq(false)
      expect(Ability.new(FactoryBot.create(:user)).
               can?(:read, holding_pen.incoming_messages.last)).to eq(false)
    end
  end
end
