require 'spec_helper'

RSpec.describe 'Admin incoming messages', type: :request do
  let(:admin_user) { FactoryBot.create(:admin_user) }

  before { sign_in(admin_user) }

  let(:page) { Nokogiri::HTML(response.body) }

  # Every incoming message arrives with a response event, which the edit
  # page reads.
  def with_response_event(incoming_message)
    FactoryBot.create(:response_event,
                      incoming_message: incoming_message,
                      info_request: incoming_message.info_request)
    incoming_message
  end

  describe 'when destroying an incoming message' do
    before do
      @im = incoming_messages(:useless_incoming_message)
    end

    it "destroys the ActiveStorage attachment record" do
      file = @im.raw_email.file
      expect(file.attached?).to eq true
      delete admin_incoming_message_path(@im)
      expect { file.reload }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it 'destroys the incoming message' do
      delete admin_incoming_message_path(@im)
      expect(IncomingMessage).not_to exist(@im.id)
      expect(flash[:notice]).to eq('Incoming message successfully destroyed.')
    end

    it 'expires the file cache for the associated info_request' do
      info_request = FactoryBot.create(:info_request)
      allow(@im).to receive(:info_request).and_return(info_request)
      allow(IncomingMessage).to receive(:find).and_return(@im)
      expect(@im.info_request).
        to receive(:expire).
        with(preserve_database_cache: true)
      delete admin_incoming_message_path(@im)
    end

    it 'redirects to request admin' do
      delete admin_incoming_message_path(@im)
      expect(response).to redirect_to admin_request_url(@im.info_request)
    end

    it 'does not log a deletion event if destroy! fails' do
      info_request = @im.info_request
      allow_any_instance_of(IncomingMessage).
        to receive(:destroy!).
        and_raise(ActiveRecord::RecordNotDestroyed.new('failed', @im))

      expect { delete admin_incoming_message_path(@im) }.
        to raise_error(ActiveRecord::RecordNotDestroyed)
      expect(IncomingMessage).to exist(@im.id)
      expect(info_request.info_request_events.
        where(event_type: 'destroy_incoming')).to be_empty
    end
  end

  describe 'when editing an incoming message' do
    before do
      @incoming = with_response_event(FactoryBot.create(:incoming_message))
    end

    it 'should be successful' do
      get edit_admin_incoming_message_path(@incoming)
      expect(response).to be_successful
    end

    it 'shows the edit page for the incoming message' do
      get edit_admin_incoming_message_path(@incoming)
      expect(page.at_css('h1').text).
        to eq("Incoming message #{@incoming.id}")
      form_path = admin_incoming_message_path(@incoming)
      expect(page.at_css("form[action='#{form_path}']")).to be_present
    end
  end

  describe 'when updating an incoming message' do
    before do
      @incoming = with_response_event(
        FactoryBot.create(:incoming_message, prominence: 'normal')
      )
      @default_params = {
        incoming_message: {
          prominence: 'hidden',
          prominence_reason: 'dull',
          tag_string: 'foo'
        }
      }
    end

    def make_request(params = @default_params)
      put admin_incoming_message_path(@incoming), params: params
    end

    it 'should save the prominence of the message' do
      make_request
      @incoming.reload
      expect(@incoming.prominence).to eq('hidden')
    end

    it 'should save a prominence reason for the message' do
      make_request
      @incoming.reload
      expect(@incoming.prominence_reason).to eq('dull')
    end

    it 'should save a tag string for the message' do
      make_request
      @incoming.reload
      expect(@incoming.tag_string).to eq('foo')
    end

    it 'should log an "edit_incoming" event on the info_request' do
      make_request
      @incoming.reload
      last_event = @incoming.info_request_events.last
      expect(last_event.event_type).to eq('edit_incoming')
      expect(last_event.params).to eq(
        incoming_message: { gid: @incoming.to_global_id.to_s },
        editor: admin_user.url_name,
        old_prominence: 'normal',
        prominence: 'hidden',
        old_prominence_reason: nil,
        prominence_reason: 'dull',
        old_tag_string: '',
        tag_string: 'foo'
      )
    end

    it 'should expire the file cache for the info request' do
      info_request = FactoryBot.create(:info_request)
      allow(IncomingMessage).to receive(:find).and_return(@incoming)
      allow(@incoming).to receive(:info_request).and_return(info_request)
      expect(info_request).to receive(:expire)
      make_request
    end

    context 'if the incoming message saves correctly' do
      it 'should redirect to the admin info request view' do
        make_request
        expect(response).
          to redirect_to admin_request_url(@incoming.info_request)
      end

      it 'should show a message that the incoming message has been updated' do
        make_request
        expect(flash[:notice]).to eq('Incoming message successfully updated.')
      end
    end

    context 'if the incoming message is not valid' do
      it 'shows the edit page again' do
        make_request({ incoming_message: { prominence: 'fantastic',
                                           prominence_reason: 'dull' } })
        expect(response).to have_http_status(:unprocessable_content)
        expect(page.at_css('h1').text).
          to eq("Incoming message #{@incoming.id}")
        form_path = admin_incoming_message_path(@incoming)
        expect(page.at_css("form[action='#{form_path}']")).to be_present
        expect(@incoming.reload.prominence).to eq('normal')
      end
    end
  end

  describe "when destroying multiple incoming messages" do
    let(:info_request) { FactoryBot.create(:info_request) }
    let(:spam1) do
      FactoryBot.create(:incoming_message, subject: "Buy a watch!1!!",
                                           info_request: info_request)
    end
    let(:spam2) do
      FactoryBot.create(:incoming_message, subject: "Best cheap w@tches!!1!",
                                           info_request: info_request)
    end
    let(:spam_ids) { [spam1.id, spam2.id] }

    context 'when showing the confirmation page' do
      it 'carries only scoped message ids and the request id in hidden fields' do
        other_request = FactoryBot.create(:info_request)
        other_message = FactoryBot.create(:incoming_message,
                                          info_request: other_request)

        post bulk_destroy_admin_incoming_messages_path, params: {
          request_id: info_request.id.to_s,
          ids: [spam1.id, other_message.id].join(',')
        }

        expect(response).to have_http_status(:ok)
        expect(page.at_css('input[type=hidden][name=ids]')['value']).
          to eq(spam1.id.to_s)
        expect(page.at_css('input[type=hidden][name=request_id]')['value']).
          to eq(info_request.id.to_s)
      end
    end

    context "the user confirms deletion" do
      it "destroys the selected messages" do
        post bulk_destroy_admin_incoming_messages_path, params: {
          request_id: info_request.id,
          ids: spam_ids.join(","),
          commit: "Yes"
        }

        expect(IncomingMessage.where(id: spam_ids)).to be_empty
      end

      it 'expires the file cache for the associated info_request' do
        allow(InfoRequest).to receive(:find).and_return(info_request)
        expect(info_request).
          to receive(:expire).with(preserve_database_cache: true)
        post bulk_destroy_admin_incoming_messages_path, params: {
          request_id: info_request.id,
          ids: spam_ids.join(","),
          commit: "Yes"
        }
      end

      it "redirects back to the admin page for the request" do
        post bulk_destroy_admin_incoming_messages_path, params: {
          request_id: info_request.id,
          ids: spam_ids.join(","),
          commit: "Yes"
        }

        expect(response).to redirect_to(admin_request_url(info_request))
      end

      it "sets a success message in flash" do
        post bulk_destroy_admin_incoming_messages_path, params: {
          request_id: info_request.id,
          ids: spam_ids.join(","),
          commit: "Yes"
        }

        expect(response).to redirect_to(admin_request_url(info_request))
        expect(flash[:notice]).
          to eq("Incoming messages successfully destroyed.")
      end

      it "only destroys selected messages" do
        post bulk_destroy_admin_incoming_messages_path, params: {
          request_id: info_request.id,
          ids: spam2.id,
          commit: "Yes"
        }

        expect(IncomingMessage.where(id: spam_ids)).to eq([spam1])
      end

      it 'does not destroy a message from another request' do
        other_request = FactoryBot.create(:info_request)
        other_message = FactoryBot.create(:incoming_message,
                                          info_request: other_request)

        post bulk_destroy_admin_incoming_messages_path, params: {
          request_id: info_request.id,
          ids: [spam1.id, other_message.id].join(','),
          commit: 'Yes'
        }

        expect(IncomingMessage).not_to exist(spam1.id)
        expect(IncomingMessage).to exist(other_message.id)
        expect(other_request.info_request_events.
          where(event_type: 'destroy_incoming')).to be_empty
      end

      it 'rejects a non-string selection without deleting messages' do
        post bulk_destroy_admin_incoming_messages_path, params: {
          request_id: info_request.id,
          ids: [spam1.id],
          commit: 'Yes'
        }

        expect(response).to have_http_status(:bad_request)
        expect(IncomingMessage).to exist(spam1.id)
      end

      context "not all the messages can be destroyed" do
        it 'reports the failure without recording a deletion event' do
          failed_id = spam2.id
          allow_any_instance_of(IncomingMessage).
            to receive(:destroy!).and_wrap_original do |method|
              raise 'private reply text' if method.receiver.id == failed_id

              method.call
            end
          error_text = "Unable to destroy incoming message #{failed_id}: " \
                       'RuntimeError'
          expect(Rails.logger).to receive(:error).with(error_text)
          msg = "Incoming Messages #{spam2.id} could not be destroyed"
          post bulk_destroy_admin_incoming_messages_path, params: {
            request_id: info_request.id,
            ids: spam_ids.join(","),
            commit: "Yes"
          }

          expect(flash[:error]).to match(msg)
          expect(IncomingMessage).to exist(failed_id)
          expect(info_request.info_request_events.
            where(event_type: 'destroy_incoming').count).to eq(1)
        end
      end
    end

    context "the user does not confirm deletion" do
      it "does not destroy the messages" do
        post bulk_destroy_admin_incoming_messages_path, params: {
          request_id: info_request.id,
          ids: spam_ids,
          commit: "No"
        }

        expect(IncomingMessage.where(id: spam_ids)).
          to match_array([spam1, spam2])
      end

      it "redirects back to the admin page for the request" do
        post bulk_destroy_admin_incoming_messages_path, params: {
          request_id: info_request.id,
          ids: spam_ids.join(","),
          commit: "No"
        }

        expect(response).to redirect_to(admin_request_url(info_request))
      end

      it 'redirects without ids' do
        post bulk_destroy_admin_incoming_messages_path, params: {
          request_id: info_request.id,
          commit: 'No'
        }

        expect(response).to redirect_to(admin_request_url(info_request))
      end
    end
  end
end
