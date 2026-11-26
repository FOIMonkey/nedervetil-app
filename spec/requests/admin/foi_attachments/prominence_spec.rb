require 'spec_helper'

RSpec.describe 'Admin attachment prominence', type: :request do
  let(:admin_user) { FactoryBot.create(:admin_user) }

  before { sign_in(admin_user) }

  let(:info_request) { FactoryBot.create(:info_request, :with_plain_incoming) }
  let(:incoming_message) { info_request.incoming_messages.first }
  let!(:attachment) { incoming_message.foi_attachments.first }

  describe 'PATCH #update' do
    let(:prominence_path) { admin_foi_attachment_prominence_path(attachment) }

    let(:params) do
      {
        foi_attachment: {
          prominence: 'hidden',
          prominence_reason: 'Contains personal information'
        }
      }
    end

    context 'on a successful update' do
      it 'updates the prominence' do
        patch prominence_path, params: params
        expect(attachment.reload.prominence).to eq('hidden')
      end

      it 'updates the prominence_reason' do
        patch prominence_path, params: params
        expect(attachment.reload.prominence_reason).
          to eq('Contains personal information')
      end

      it 'expires the attachment' do
        expect_any_instance_of(FoiAttachment).to receive(:expire)
        patch prominence_path, params: params
      end

      it 'sets a success notice' do
        patch prominence_path, params: params
        expect(flash[:notice]).to eq('Prominence updated.')
      end

      it 'redirects to the attachment edit page' do
        patch prominence_path, params: params
        expect(response).to redirect_to(
          edit_admin_foi_attachment_path(attachment)
        )
      end

      it 'logs an edit_attachment event on the info_request' do
        patch prominence_path, params: params

        info_request.reload
        last_event = info_request.info_request_events.last
        expect(last_event.event_type).to eq('edit_attachment')
        expect(last_event.params).to include(
          editor: admin_user.url_name,
          attachment_id: attachment.id,
          old_prominence: 'requester_only',
          prominence: 'hidden',
          old_prominence_reason: nil,
          prominence_reason: 'Contains personal information'
        )
      end
    end

    context 'on an unsuccessful update' do
      let(:params) do
        {
          foi_attachment: {
            prominence: 'invalid_prominence',
            prominence_reason: 'Contains personal information'
          }
        }
      end

      it 'leaves the attachment as it was' do
        patch prominence_path, params: params
        attachment.reload
        expect(attachment.prominence).to eq('requester_only')
        expect(attachment.prominence_reason).to be_nil
      end

      it 'does not expire the attachment' do
        expect_any_instance_of(FoiAttachment).not_to receive(:expire)
        patch prominence_path, params: params
      end

      it 'sets an error flash' do
        patch prominence_path, params: params
        expect(flash[:error]).to eq('Prominence is not included in the list')
      end

      it 'redirects to the attachment edit page' do
        patch prominence_path, params: params
        expect(response).to redirect_to(
          edit_admin_foi_attachment_path(attachment)
        )
      end
    end

    context 'when setting prominence to public' do
      let(:params) do
        {
          foi_attachment: {
            prominence: 'public',
            prominence_reason: 'Trying to publish directly'
          }
        }
      end

      it 'refuses the change and leaves the attachment untouched' do
        expect { patch prominence_path, params: params }.
          not_to(change { info_request.info_request_events.count })

        attachment.reload
        expect(attachment.prominence).to eq('requester_only')
        expect(attachment.prominence_reason).to be_nil
        expect(flash[:error]).to eq('Prominence is not included in the list')
        expect(response).to redirect_to(
          edit_admin_foi_attachment_path(attachment)
        )
      end

      it 'does not expire the attachment' do
        expect_any_instance_of(FoiAttachment).not_to receive(:expire)
        patch prominence_path, params: params
      end
    end

    context 'when the attachment is already public' do
      before { attachment.make_public! }

      it 'refuses a blank prominence and leaves the attachment public' do
        expect do
          patch prominence_path,
                params: { foi_attachment: { prominence: '',
                                            prominence_reason: 'Note' } }
        end.not_to(change { info_request.info_request_events.count })

        attachment.reload
        expect(attachment.prominence).to eq('public')
        expect(attachment.prominence_reason).to be_nil
        expect(flash[:error]).to eq('Prominence is not included in the list')
        expect(response).to redirect_to(
          edit_admin_foi_attachment_path(attachment)
        )
      end

      it 'refuses setting prominence to public' do
        patch prominence_path,
              params: { foi_attachment: { prominence: 'public',
                                          prominence_reason: 'Note' } }

        attachment.reload
        expect(attachment.prominence).to eq('public')
        expect(attachment.prominence_reason).to be_nil
        expect(flash[:error]).to eq('Prominence is not included in the list')
      end

      it 'allows changing prominence to requester_only' do
        patch prominence_path,
              params: { foi_attachment: { prominence: 'requester_only',
                                          prominence_reason: 'Taking down' } }

        expect(attachment.reload.prominence).to eq('requester_only')
        expect(flash[:notice]).to eq('Prominence updated.')
        last_event = info_request.info_request_events.last
        expect(last_event.params).to include(
          old_prominence: 'public',
          prominence: 'requester_only'
        )
      end
    end
  end
end
