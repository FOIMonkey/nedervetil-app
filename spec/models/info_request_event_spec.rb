# == Schema Information
#
# Table name: info_request_events
#
#  id                  :integer          not null, primary key
#  info_request_id     :integer          not null
#  event_type          :text             not null
#  created_at          :datetime         not null
#  described_state     :string
#  calculated_state    :string
#  last_described_at   :datetime
#  incoming_message_id :integer
#  outgoing_message_id :integer
#  updated_at          :datetime
#  params              :jsonb
#

require 'spec_helper'

RSpec.describe InfoRequestEvent do
  describe 'event_type scopes' do
    described_class::EVENT_TYPES.each do |event_type|
      it "for '#{event_type}' events" do
        expect(described_class.public_send("#{event_type}_events").to_sql).
          to eq(described_class.where(event_type: event_type).to_sql)
      end
    end
  end

  describe 'validations' do
    subject(:ire) { FactoryBot.build(:info_request_event) }

    it { is_expected.to be_valid }

    it 'requires info_request' do
      ire.info_request = nil
      expect(ire).not_to be_valid
    end
  end

  describe "when checking for a valid state" do
    it 'should add an error message for described_state if it is not valid' do
      ire = InfoRequestEvent.new(described_state: 'nope')
      ire.valid?
      expect(ire.errors.messages[:described_state]).
        to eq ["is not a valid state"]
    end

    it 'should not add an error message for described_state if it is valid' do
      ire = InfoRequestEvent.new(described_state: 'waiting_response')
      ire.valid?
      expect(ire.errors.messages[:described_state]).to be_blank
    end
  end

  describe "when storing serialized parameters" do
    let(:ire) { InfoRequestEvent.new }

    it "should convert event parameters into YAML and back successfully" do
      example_params = { foo: 'this is stuff', bar: 83, humbug: "yikes!!!" }
      ire.params = example_params
      expect(ire.params).to eq(example_params)
    end

    it "should store the incoming_message and outgoing_message ids" do
      example_params = { incoming_message_id: 1,
                         outgoing_message_id: 2 }
      ire.params = example_params
      expect(ire.incoming_message_id).to eq(1)
      expect(ire.outgoing_message_id).to eq(2)
    end

    it "allow events to be created when association to deleted records" do
      rule = FactoryBot.create(:censor_rule)
      rule.destroy
      ire = FactoryBot.create(:info_request_event, params: { rule: rule })
      expect(ire.params[:rule]).to eq(rule.to_gid.to_s)
    end

    it 'stores keys suffixed with ID as GID' do
      rule = FactoryBot.create(:censor_rule)
      ire.params = { censor_rule_id: rule.id }
      expect(ire.params).to include(
        censor_rule: { gid: rule.to_global_id.to_s }
      )
    end

    it 'stores model instances as GID' do
      rule = FactoryBot.create(:censor_rule)
      ire.params = { rule: rule }
      expect(ire.params).to include(
        rule: { gid: rule.to_global_id.to_s }
      )
    end

    it 'stores correct class GID for AlaveteliPro models' do
      ire.params = { request_summary_id: 404_404 }

      expect(ire.params).to include(
        request_summary: {
          gid: 'gid://app/AlaveteliPro::RequestSummary/404404'
        }
      )
    end

    it "stores key/value as-is if they can't be mapped to the correct class" do
      ire.params = { foo_id: 4 }
      expect(ire.params).to include(foo_id: 4)
    end

    it 'memoizes params and GlobalID lookups across repeated reads' do
      rule = FactoryBot.create(:censor_rule)
      event = FactoryBot.create(:info_request_event, params: { rule: rule })

      expect(GlobalID::Locator).to receive(:locate).
        with(rule.to_global_id.to_s).once.and_call_original

      expect(event.params[:rule]).to eq(rule)
      expect(event.params[:rule]).to eq(rule)
      expect(event.params).to include(rule: { gid: rule.to_global_id.to_s })
    end

    it 'memoizes missing GlobalID lookups without querying twice' do
      rule = FactoryBot.create(:censor_rule)
      gid = rule.to_global_id.to_s
      rule.destroy
      event = FactoryBot.create(:info_request_event, params: { rule: rule })

      expect(GlobalID::Locator).to receive(:locate).
        with(gid).once.and_call_original

      expect(event.params[:rule]).to eq(gid)
      expect(event.params[:rule]).to eq(gid)
    end

    it 'invalidates memoized params on reassignment, write_attribute and reload' do
      event = FactoryBot.create(:info_request_event, params: { foo: 'one' })
      expect(event.params[:foo]).to eq('one')

      event.params = { foo: 'two' }
      expect(event.params[:foo]).to eq('two')

      event.write_attribute(:params, { 'foo' => 'three' })
      expect(event.params[:foo]).to eq('three')

      event.reload
      expect(event.params[:foo]).to eq('one')

      event.write_attribute(:params, nil)
      expect(event.params).to be_nil
    end

    it 'does not share memoized params across dup' do
      event = FactoryBot.create(:info_request_event, params: { foo: 'one' })
      expect(event.params[:foo]).to eq('one')

      copy = event.dup
      copy.params = { foo: 'two' }
      expect(copy.params[:foo]).to eq('two')
      expect(event.params[:foo]).to eq('one')
    end
  end

  describe '#visible?' do
    context 'is a legacy comment event' do
      it 'should return false, as comments are gone' do
        ire = FactoryBot.create(:info_request_event, event_type: 'comment')
        expect(ire.visible?).to eq(false)
      end
    end

    context 'is not a comment' do
      it 'should return true' do
        ire = FactoryBot.create(:info_request_event)
        expect(ire.visible?).to eq(true)
      end
    end
  end

  describe '#params_diff' do
    let(:ire) { InfoRequestEvent.new }

    it "should return old, new and other params" do
      ire.params = { old_foo: 'this is stuff', foo: 'stuff', bar: 84 }
      expected_hash = {
        new: { foo: 'stuff' },
        old: { foo: 'this is stuff' },
        other: { bar: 84 }
      }
      expect(ire.params_diff).to eq(expected_hash)
    end

    it 'should drop matching old and new values' do
      ire.params = { old_foo: 'stuff', foo: 'stuff', bar: 84 }
      expected_hash = { new: {}, old: {}, other: { bar: 84 } }
      expect(ire.params_diff).to eq(expected_hash)
    end

    it 'returns a url_name if passed a User' do
      user = FactoryBot.create(:user)
      ire.params = { old_foo: "", foo: user }
      expected_hash = {
        new: { foo: { gid: user.to_global_id.to_s } },
        old: { foo: '' },
        other: {}
      }
      expect(ire.params_diff).to eq(expected_hash)
    end
  end

  describe 'after saving' do
    let(:request) { FactoryBot.create(:info_request) }

    context "the incoming_message is not hidden" do
      it "updates the parent info_request's last_public_response_at value" do
        im = FactoryBot.create(:incoming_message)
        response_event = FactoryBot.
                          create(:info_request_event, event_type: 'response',
                                                      info_request: request,
                                                      incoming_message: im)
        expect(request.last_public_response_at).to be_within(1.second).
            of response_event.created_at
      end
    end

    context "the event is not a response" do
      it "does not update the info_request's last_public_response_at value" do
        expect_any_instance_of(InfoRequestEvent).not_to receive(:update_request)
        FactoryBot.create(:info_request_event, event_type: 'edit',
                                               info_request: request)
        expect(request.last_public_response_at).to be_nil
      end
    end

    context "the incoming_message is hidden" do
      it "sets the parent info_request's last_public_response_at to nil" do
        im = FactoryBot.create(:incoming_message, prominence: 'hidden')
        FactoryBot.create(:info_request_event, event_type: 'response',
                                               info_request: request,
                                               incoming_message: im)
        expect(request.last_public_response_at).to be_nil
      end
    end

    it "calls the request's create_or_update_request_summary on create" do
      info_request = FactoryBot.create(:info_request)
      event = FactoryBot.build(:info_request_event, info_request: info_request)
      expect(event.info_request).to receive(:create_or_update_request_summary)
      event.save!
    end
  end

  describe "should know" do
    it "that it's an incoming message" do
      event = InfoRequestEvent.new(
        incoming_message: FactoryBot.build_stubbed(:incoming_message)
      )
      expect(event.is_incoming_message?).to be_truthy
      expect(event.is_outgoing_message?).to be_falsey
    end

    it "that it's an outgoing message" do
      event = InfoRequestEvent.new(
        outgoing_message: FactoryBot.build_stubbed(:initial_request)
      )
      event.id = 1
      expect(event.is_incoming_message?).to be_falsey
      expect(event.is_outgoing_message?).to be_truthy
    end
  end

  describe 'when asked if it has the same email as a previous send' do
    let(:info_request_event) { InfoRequestEvent.new }

    it 'should return true if the email in its params and the previous email the request was sent to are both nil' do
      allow(info_request_event).to receive(:params).and_return({})
      allow(info_request_event).
        to receive_message_chain(:info_request, :get_previous_email_sent_to).
        and_return(nil)
      expect(info_request_event.same_email_as_previous_send?).to be true
    end

    it 'should return false if one email address exists and the other does not' do
      allow(info_request_event).
        to receive(:params).and_return(email: 'test@example.com')
      allow(info_request_event).
        to receive_message_chain(:info_request, :get_previous_email_sent_to).
        and_return(nil)
      expect(info_request_event.same_email_as_previous_send?).to be false
    end

    it 'should return true if the addresses are identical' do
      allow(info_request_event).
        to receive(:params).and_return(email: 'test@example.com')
      allow(info_request_event).
        to receive_message_chain(:info_request, :get_previous_email_sent_to).
        and_return('test@example.com')
      expect(info_request_event.same_email_as_previous_send?).to be true
    end

    it 'should return false if the addresses are different' do
      allow(info_request_event).
        to receive(:params).and_return(email: 'test@example.com')
      allow(info_request_event).
        to receive_message_chain(:info_request, :get_previous_email_sent_to).
        and_return('different@example.com')
      expect(info_request_event.same_email_as_previous_send?).to be false
    end

    it 'should return true if the addresses have different formats' do
      allow(info_request_event).
        to receive(:params).and_return(email: 'A Test <test@example.com>')
      allow(info_request_event).
        to receive_message_chain(:info_request, :get_previous_email_sent_to).
        and_return('test@example.com')
      expect(info_request_event.same_email_as_previous_send?).to be true
    end

    it 'should handle non-ascii characters in the name input' do
      address = "\"Someone’s name\" <test@example.com>"
      allow(info_request_event).to receive(:params).and_return(email: address)
      allow(info_request_event).
        to receive_message_chain(:info_request, :get_previous_email_sent_to).
        and_return(address)
      expect(info_request_event.same_email_as_previous_send?).to be true
    end
  end

  describe '#set_calculated_state!' do
    let(:info_request_event) { FactoryBot.build(:sent_event) }

    before do
      info_request_event.set_calculated_state!('sent')
      @timestamp = info_request_event.last_described_at
    end

    context 'when the existing state is the same as the new state' do
      it 'does not set the last described at time' do
        info_request_event.set_calculated_state!('sent')
        expect(info_request_event.last_described_at).to eql(@timestamp)
      end
    end

    context 'when the existing state is not the same as the new state' do
      it 'sets the last described at time' do
        info_request_event.set_calculated_state!('response')
        expect(info_request_event.last_described_at).to be > @timestamp
      end

      it 'sets the calculated state' do
        info_request_event.set_calculated_state!('response')
        expect(info_request_event.calculated_state).to eql('response')
      end
    end
  end

  describe '#destroy' do
    let(:info_request) { FactoryBot.create(:info_request) }
    let(:event) {
                   InfoRequestEvent.create(info_request: info_request,
                                           event_type: 'sent',
                                           params: {})
                 }

    it 'should destroy the info_request_event' do
      event.destroy
      expect(InfoRequestEvent.where(id: event.id)).to be_empty
    end

    it 'should destroy associated user_info_request_sent_alerts' do
      user = FactoryBot.create(:user)
      UserInfoRequestSentAlert.create(info_request_event_id: event.id,
                                      alert_type: 'overdue_1',
                                      user: user,
                                      info_request: info_request)
      event.destroy
      expect(UserInfoRequestSentAlert.where(info_request_event_id: event.id)).
        to be_empty
    end
  end

  describe '#resets_due_dates?' do
    it 'returns true if the event is a sending of the request' do
      info_request_event = FactoryBot.create(:sent_event)
      expect(info_request_event.resets_due_dates?).to be true
    end

    it 'returns true if the event is a clarification' do
      info_request = FactoryBot.create(:info_request)
      info_request.set_described_state('waiting_clarification')
      event = info_request.log_event('followup_sent', {})
      expect(event.resets_due_dates?).to be true
    end

    it 'returns true if the event is a failed send of a request' do
      info_request_event = FactoryBot.create(:failed_sent_request_event)
      expect(info_request_event.resets_due_dates?).to be true
    end

    it 'returns false if the event is a failed send of a followup' do
      info_request_event = FactoryBot.create(:failed_sent_followup_event)
      expect(info_request_event.resets_due_dates?).to be false
    end

    it 'returns false if the event is neither a sending of the request or a
        clarification' do
      info_request_event = FactoryBot.create(:response_event)
      expect(info_request_event.resets_due_dates?).to be false
    end
  end

  describe '#is_request_sending?' do
    it 'returns true if the event type is "sent"' do
      info_request_event = FactoryBot.create(:sent_event)
      expect(info_request_event.is_request_sending?).to be true
    end

    it 'returns true if the event type is "resent"' do
      info_request_event = FactoryBot.create(:resent_event)
      expect(info_request_event.is_request_sending?).to be true
    end

    it 'returns true if the event is a failed send of a request' do
      info_request_event = FactoryBot.create(:failed_sent_request_event)
      expect(info_request_event.is_request_sending?).to be true
    end

    it 'returns false if the event is a failed send of a followup' do
      info_request_event = FactoryBot.create(:failed_sent_followup_event)
      expect(info_request_event.is_request_sending?).to be false
    end

    it 'returns false if the event type is not "sent" or "resent"' do
      info_request_event = FactoryBot.create(:response_event)
      expect(info_request_event.is_request_sending?).to be false
    end
  end

  describe '#is_clarification?' do
    it 'should return false if there has been no request for clarification' do
      info_request = FactoryBot.create(:info_request_with_incoming)
      event = info_request.log_event('followup_sent', {})
      expect(event.is_clarification?).to be false
    end

    it 'should return true if the event is the first followup after a request
        for clarification' do
      info_request = FactoryBot.create(:info_request_with_incoming)
      info_request.set_described_state('waiting_clarification')
      event = info_request.log_event('followup_sent', {})
      expect(event.is_clarification?).to be true
    end

    it 'should return false if there was a request for clarification but there
        has since been a followup' do
      info_request = FactoryBot.create(:info_request_with_incoming)
      info_request.set_described_state('waiting_clarification')
      info_request.log_event('followup_sent', {})
      event = info_request.log_event('followup_sent', {})
      expect(event.is_clarification?).to be false
    end

    it 'should return false if there was a request for clarification after
        this event' do
      info_request = FactoryBot.create(:info_request_with_incoming)
      event = info_request.log_event('followup_sent', {})
      info_request.set_described_state('waiting_clarification')
      expect(event.is_clarification?).to be false
    end
  end

  describe 'notifications' do
    it 'deletes associated notifications when destroyed' do
      notification = FactoryBot.create(:notification)
      info_request_event = notification.info_request_event
      expect(Notification.where(id: notification.id)).to exist
      info_request_event.destroy
      expect(Notification.where(id: notification.id)).not_to exist
    end
  end

  describe '#recheck_due_dates' do
    context 'if the event is a response that is then labelled as
             a clarification request' do
      let(:response_event) do
        response = nil
        travel_to(1.month.ago) do
          response = FactoryBot.create(:response_event)
        end
        response.described_state = 'waiting_clarification'
        response.calculated_state = 'waiting_clarification'
        response.save!
        response
      end

      context 'if there is a subsequent followup' do
        let!(:followup) do
          FactoryBot.create(:followup_sent_event,
                            info_request: response_event.info_request)
        end

        it 'resets the due dates on the request' do
          info_request = response_event.info_request
          expect(info_request.reload.date_initial_request_last_sent_at).
            to eq(1.month.ago.to_date)
          response_event.recheck_due_dates
          expect(info_request.reload.date_initial_request_last_sent_at).
            to eq(Time.zone.now.to_date)
        end
      end

      context 'if there is no subsequent followup' do
        it 'does not reset the due dates on the request' do
          info_request = response_event.info_request
          expect(info_request.reload.date_initial_request_last_sent_at).
            to eq(1.month.ago.to_date)
          response_event.recheck_due_dates
          expect(info_request.reload.date_initial_request_last_sent_at).
            to eq(1.month.ago.to_date)
        end
      end
    end
  end

  describe '#foi_attachment' do
    it 'loads FoiAttachment from params as if it was an association' do
      event = FactoryBot.build(
        :info_request_event, params: { attachment_id: 1 }
      )

      attachment = instance_double(FoiAttachment)
      allow(FoiAttachment).to receive(:find).with(1).and_return(attachment)

      expect(event.foi_attachment).to eq(attachment)
    end
  end
end
