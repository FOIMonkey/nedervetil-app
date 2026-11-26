require 'spec_helper'

RSpec.describe 'Admin outgoing messages', type: :request do
  let(:admin_user) { FactoryBot.create(:admin_user) }

  before { sign_in(admin_user) }

  let(:page) { Nokogiri::HTML(response.body) }

  describe 'GET index' do
    let(:info_request) { FactoryBot.create(:info_request) }
    let(:outgoing) { info_request.outgoing_messages.first }

    def listed_ids
      page.css('#outgoing_messages .accordion-heading a[href$="/edit"]').
        map { |link| link['href'][%r{/outgoing_messages/(\d+)/edit}, 1].to_i }
    end

    it 'is successful' do
      get admin_outgoing_messages_path
      expect(response).to have_http_status(:ok)
      expect(page.at_css('h1').text).to eq('Listing outgoing messages')
    end

    it 'lists all outgoing messages' do
      outgoing
      get admin_outgoing_messages_path
      expect(listed_ids).to match_array(OutgoingMessage.pluck(:id))
    end

    it 'lists them newest first' do
      FactoryBot.create_list(:info_request, 2)
      get admin_outgoing_messages_path
      expect(listed_ids.size).to be > 1
      expect(listed_ids).to eq(listed_ids.sort.reverse)
    end

    it 'finds outgoing messages matching a query' do
      outgoing.update!(from_name: 'A Very Distinctive Name')
      get admin_outgoing_messages_path, params: { query: 'distinctive' }
      expect(listed_ids).to eq([outgoing.id])
    end

    it 'lists the best match first', :postgresql do
      FactoryBot.create(:initial_request, from_name: 'Need more data!')
      strong = FactoryBot.create(:initial_request, from_name: 'Data Data Data')
      get admin_outgoing_messages_path, params: { query: 'data' }
      expect(listed_ids.first).to eq(strong.id)
    end
  end

  describe 'GET edit' do
    let(:info_request) { FactoryBot.create(:info_request) }
    let(:outgoing) { info_request.outgoing_messages.first }

    def destroy_button
      page.at_css(%(form[action="#{admin_outgoing_message_path(outgoing)}"] ) +
                  'input[value="Destroy outgoing message"]')
    end

    it 'shows the edit page for the outgoing message' do
      get edit_admin_outgoing_message_path(outgoing)
      expect(response).to have_http_status(:ok)
      expect(page.at_css('h1').text).to eq("Outgoing message #{outgoing.id}")
      expect(page.at_css('#outgoing_message_body').text.strip).
        to eq(outgoing.raw_body)
    end

    context 'when the message is the initial outgoing message' do
      it 'does not offer to destroy it' do
        get edit_admin_outgoing_message_path(outgoing)
        expect(destroy_button['disabled']).to be_present
        expect(response.body).
          to include('The initial outgoing message cannot be destroyed.')
      end
    end

    context 'when the message is not initial outgoing message' do
      let(:outgoing) do
        FactoryBot.create(:new_information_followup,
                          info_request: info_request)
      end

      it 'offers to destroy it' do
        get edit_admin_outgoing_message_path(outgoing)
        expect(destroy_button).to be_present
        expect(destroy_button['disabled']).to be_nil
        expect(response.body).
          not_to include('The initial outgoing message cannot be destroyed.')
      end
    end
  end

  describe 'DELETE destroy' do
    let(:info_request) { FactoryBot.create(:info_request) }
    let(:outgoing) do
      FactoryBot.create(:new_information_followup,
                        info_request: info_request)
    end

    context 'successfully destroying the message' do
      it 'destroys the message' do
        delete admin_outgoing_message_path(outgoing)
        expect(OutgoingMessage).not_to exist(outgoing.id)
      end

      it 'logs an event on the info request' do
        delete admin_outgoing_message_path(outgoing)
        expect(info_request.reload.last_event.event_type).
          to eq('destroy_outgoing')
      end

      it 'informs the user' do
        delete admin_outgoing_message_path(outgoing)
        expect(flash[:notice]).to eq('Outgoing message successfully destroyed.')
      end

      it 'redirects to the admin request page' do
        delete admin_outgoing_message_path(outgoing)
        expect(response).to redirect_to(admin_request_url(info_request))
      end
    end

    context 'unsuccessfully destroying the message' do
      before do
        allow_any_instance_of(OutgoingMessage).
          to receive(:destroy).and_return(false)
      end

      it 'does not destroy the message' do
        delete admin_outgoing_message_path(outgoing)
        expect(OutgoingMessage).to exist(outgoing.id)
        expect(response).
          to redirect_to(edit_admin_outgoing_message_path(outgoing))
      end

      it 'informs the user' do
        delete admin_outgoing_message_path(outgoing)
        expect(flash[:error]).to eq('Could not destroy the outgoing message.')
      end

      it 'redirects to the outgoing message edit page' do
        delete admin_outgoing_message_path(outgoing)
        expect(response).
          to redirect_to(edit_admin_outgoing_message_path(outgoing))
      end
    end

    context 'when the message is the initial outgoing message' do
      let(:outgoing) { FactoryBot.create(:initial_request) }

      it 'prevents the destruction of the message' do
        delete admin_outgoing_message_path(outgoing)
        expect(OutgoingMessage).to exist(outgoing.id)
        expect(flash[:error]).to eq('Could not destroy the outgoing message.')
        expect(response).
          to redirect_to(edit_admin_outgoing_message_path(outgoing))
      end
    end

    context 'when the message is not initial outgoing message' do
      it 'allows the destruction of the message' do
        delete admin_outgoing_message_path(outgoing)
        expect(OutgoingMessage).not_to exist(outgoing.id)
        expect(response).to redirect_to(admin_request_url(info_request))
      end
    end
  end

  describe 'PUT update' do
    let(:info_request) { FactoryBot.create(:info_request) }
    let(:outgoing) { info_request.outgoing_messages.first }
    let(:default_params) do
      {
        outgoing_message: {
          prominence: 'hidden',
          prominence_reason: 'dull',
          body: 'changed body',
          tag_string: 'foo'
        }
      }
    end

    def make_request(params = default_params, message = outgoing)
      put admin_outgoing_message_path(message), params: params
    end

    it 'should save a change to the body of the message' do
      make_request
      outgoing.reload
      expect(outgoing.body).to eq('changed body')
    end

    it 'should save the prominence of the message' do
      make_request
      outgoing.reload
      expect(outgoing.prominence).to eq('hidden')
    end

    it 'should save a prominence reason for the message' do
      make_request
      outgoing.reload
      expect(outgoing.prominence_reason).to eq('dull')
    end

    it 'should save a tag string for the message' do
      make_request
      outgoing.reload
      expect(outgoing.tag_string).to eq('foo')
    end

    it 'should log an "edit_outgoing" event on the info_request' do
      make_request
      info_request.reload
      last_event = info_request.info_request_events.last
      expect(last_event.event_type).to eq('edit_outgoing')
      expect(last_event.params).to eq(
        outgoing_message: { gid: outgoing.to_global_id.to_s },
        editor: admin_user.url_name,
        old_body: 'Some information please',
        body: 'changed body',
        body_changed: true,
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
      allow_any_instance_of(OutgoingMessage).
        to receive(:info_request) { info_request }

      outgoing = FactoryBot.create(:initial_request, info_request: info_request)

      expect(info_request).to receive(:expire)

      make_request(default_params, outgoing)
    end

    context 'if the outgoing message saves correctly' do
      it 'should redirect to the admin info request view' do
        make_request
        expect(response).to redirect_to admin_request_url(info_request)
      end

      it 'should show a message that the incoming message has been updated' do
        make_request
        expect(flash[:notice]).to eq('Outgoing message successfully updated.')
      end
    end

    context 'if the incoming message is not valid' do
      it 'should show the edit page again' do
        make_request({ outgoing_message: { prominence: 'fantastic',
                                           prominence_reason: 'dull',
                                           body: 'Some information please' } })
        expect(response).to have_http_status(:unprocessable_content)
        expect(page.at_css('h1').text).
          to eq("Outgoing message #{outgoing.id}")
        expect(page.at_css('#outgoing_message_body')).to be_present
        expect(outgoing.reload.prominence).to eq('normal')
      end
    end
  end

  describe 'POST resend' do
    let(:info_request) { FactoryBot.create(:info_request) }
    let(:outgoing) { info_request.outgoing_messages.first }

    it 'redirects to the admin show request page' do
      post resend_admin_outgoing_message_path(outgoing)
      expect(response).
        to redirect_to(admin_request_path(info_request))
    end

    it 'logs the message resend' do
      post resend_admin_outgoing_message_path(outgoing)
      expect(info_request.reload.last_event.event_type).to eq 'resent'
    end

    it 'raises an error if given an unexpected message type' do
      outgoing.update_attribute(:message_type, 'invalid')
      expect { post resend_admin_outgoing_message_path(outgoing) }.
        to raise_error(RuntimeError)
    end

    it 'changes info_request#updated_at' do
      travel_to(1.day.ago) { info_request }
      expect { post resend_admin_outgoing_message_path(outgoing) }.
        to change { info_request.reload.updated_at.to_date }.
          from(1.day.ago.to_date).to(Time.zone.now.to_date)
    end

    it 'reopens closed requests to new responses' do
      info_request.update(
        allow_new_responses_from: 'nobody',
        reject_incoming_at_mta: true
      )

      post resend_admin_outgoing_message_path(outgoing)
      expect(info_request.reload.allow_new_responses_from).
        to eq('anybody')
      expect(info_request.reload.reject_incoming_at_mta).to eq(false)
    end
  end
end
