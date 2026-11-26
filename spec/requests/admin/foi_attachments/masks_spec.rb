require 'spec_helper'

RSpec.describe 'Admin attachment masking', type: :request do
  let(:admin_user) { FactoryBot.create(:admin_user) }

  before { sign_in(admin_user) }

  let(:info_request) { FactoryBot.create(:info_request, :with_plain_incoming) }
  let(:incoming_message) { info_request.incoming_messages.first }
  let!(:attachment) { incoming_message.foi_attachments.first }

  describe 'POST #create' do
    let(:masks_path) { admin_foi_attachment_masks_path(attachment) }

    context 'on a successful mask' do
      it 'queues the masking job for the attachment' do
        expect { post masks_path }.
          to have_enqueued_job(FoiAttachment::MaskJob).with(attachment)
      end

      it 'sets a success notice' do
        post masks_path
        expect(flash[:notice]).to eq('Masking queued.')
      end

      it 'redirects to the attachment edit page' do
        post masks_path
        expect(response).to redirect_to(
          edit_admin_foi_attachment_path(attachment)
        )
      end
    end
  end
end
