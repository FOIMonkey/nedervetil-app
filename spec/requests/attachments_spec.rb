require 'spec_helper'

RSpec.describe 'Attachment downloads', type: :request do
  let(:request_prominence) { 'requester_only' }
  let(:message_prominence) { 'normal' }
  let(:attachment_prominence) { 'requester_only' }

  let(:info_request) do
    FactoryBot.create(:info_request, prominence: request_prominence)
  end

  let(:message) do
    FactoryBot.create(
      :incoming_message,
      info_request: info_request,
      prominence: message_prominence
    )
  end

  let(:attachment) do
    FactoryBot.create(
      :body_text,
      body: 'hereisthemaskedtext',
      incoming_message: message,
      prominence: attachment_prominence
    )
  end

  let(:verifier) do
    Rails.application.message_verifier('AttachmentsController')
  end

  def page_title
    Nokogiri::HTML(response.body).at_css('h1.page-band__title')&.text
  end

  def expect_hidden(title)
    expect(response.media_type).to eq('text/html')
    expect(page_title).to eq(title)
    expect(response.code).to eq('403')
  end

  # No copy is kept for anyone else: the response may not be stored.
  def expect_not_cached
    expect(response).to be_successful
    expect(response.headers['Cache-Control']).to eq('private, no-store')
  end

  describe 'GET show' do
    def attachment_path(params = {})
      get_attachment_path({
        request_url_title: info_request.url_title,
        incoming_message_id: message.id,
        part: attachment.url_part_number,
        file_name: attachment.display_filename
      }.merge(params))
    end

    def show(params = {}, headers = {})
      get attachment_path(params), headers: headers
    end

    it 'should redirect to the incoming message if there\'s a wrong part ' \
       'number and an ambiguous filename' do
      sign_in info_request.user
      show(
        part: attachment.url_part_number + 1,
        file_name: "invalid-#{attachment.display_filename}"
      )
      expect(response.status).to eq(303)
      expect(response).to redirect_to(incoming_message_path(message))
    end

    it 'should find a uniquely named filename even if the URL part number ' \
       'was wrong' do
      sign_in info_request.user
      show(part: 5)
      expect(response.body).to match('hereisthemaskedtext')
    end

    it 'should not download attachments with wrong file name' do
      sign_in info_request.user
      show(file_name: 'http://trying.to.hack')
      expect(response.status).to eq(303)
    end

    context 'CORS headers' do
      before { sign_in info_request.user }

      context 'with a non-CSV attachment' do
        let(:attachment) do
          FactoryBot.create(:rtf_attachment, incoming_message: message,
                                             prominence: 'requester_only')
        end

        it 'does not add CORS headers' do
          show
          expect(response.headers['Access-Control-Allow-Origin']).to be_nil
          expect(response.headers['Access-Control-Request-Method']).to be_nil
        end

        # RTF downloads as itself.
        it 'downloads the RTF file' do
          show
          expect(response).to have_http_status(:ok)
          expect(response.media_type).to eq('application/rtf')
          expect(response.body).to include('thisisthebody')
        end
      end

      it 'downloads even when a same-origin page embeds the URL as an iframe' do
        show({}, { 'Sec-Fetch-Dest' => 'iframe',
                   'Sec-Fetch-Site' => 'same-origin' })
        expect(response.headers['Content-Disposition']).
          to start_with('attachment;')
        expect(response.headers['Content-Security-Policy']).
          to include("default-src 'none'", 'sandbox')
      end

      context 'with a CSV attachment' do
        let(:attachment) do
          FactoryBot.create(:csv_attachment, incoming_message: message,
                                             prominence: 'requester_only')
        end

        it 'adds CORS headers' do
          show
          expect(response.headers['Access-Control-Allow-Origin']).to eq('*')
          expect(response.headers['Access-Control-Request-Method']).to eq('GET')
        end
      end
    end

    context 'when attachment has not been masked' do
      before { sign_in info_request.user }

      let(:attachment) do
        FactoryBot.create(
          :body_text, :unmasked,
          incoming_message: message,
          prominence: attachment_prominence
        )
      end

      context 'when masked attachment is available before timing out' do
        before do
          allow(IncomingMessage).to receive(
            :get_attachment_by_url_part_number_and_filename!
          ).and_return(attachment)
          allow(attachment).to receive(:masked?).and_return(false, true)
        end

        it 'masks the attachment' do
          expect(attachment).to receive(:mask_later)
          show
        end

        it 'redirects to show action' do
          show
          expect(response).to redirect_to(attachment_path)
        end
      end

      context 'when masking hit a fault and the part waits to be masked ' \
              'again' do
        let(:attachment) do
          FactoryBot.create(
            :body_text, :unmasked,
            incoming_message: message,
            prominence: attachment_prominence,
            masking_failed_at: Time.zone.now
          )
        end

        before do
          allow(IncomingMessage).to receive(
            :get_attachment_by_url_part_number_and_filename!
          ).and_return(attachment)
          allow(attachment).to receive(:masked?).and_return(false, true)
        end

        it 'masks it again, then serves the copy masking leaves' do
          expect(attachment).to receive(:mask_later)
          show
          expect(response).to redirect_to(attachment_path)
        end
      end

      context 'when masking hit a fault after the part was masked' do
        let(:attachment) do
          FactoryBot.create(
            :body_text,
            incoming_message: message,
            prominence: attachment_prominence,
            masking_failed_at: Time.zone.now
          )
        end

        before do
          allow(IncomingMessage).to receive(
            :get_attachment_by_url_part_number_and_filename!
          ).and_return(attachment)
        end

        it 'serves the stored copy' do
          expect(attachment).not_to receive(:mask_later)
          show
          expect(response).to have_http_status(:ok)
          expect(response.body).to eq(attachment.file.download)
        end
      end

      shared_examples 'redirects to attachment mask route' do
        it 'masks the attachment' do
          expect_any_instance_of(FoiAttachment).to receive(:mask_later)
          show
        end

        it 'redirects to wait for attachment mask route' do
          allow_any_instance_of(FoiAttachment).to receive(:to_signed_global_id).
            and_return('ABC')

          show
          expect(response).to redirect_to(
            wait_for_attachment_mask_path(
              'ABC', referer: verifier.generate(attachment_path)
            )
          )
        end
      end

      context 'when response times out waiting for masked attachment' do
        before do
          expect(Timeout).to receive(:timeout).and_raise(Timeout::Error)
        end

        include_examples 'redirects to attachment mask route'
      end

      context 'when attachment gets rebuilt' do
        before do
          allow(IncomingMessage).
            to receive(:get_attachment_by_url_part_number_and_filename!).
            and_return(attachment)
          allow(attachment).
            to receive(:reload).and_raise(ActiveRecord::RecordNotFound)
        end

        include_examples 'redirects to attachment mask route'
      end
    end

    context 'when the request is hidden' do
      let(:request_prominence) { 'hidden' }

      it 'does not download attachments' do
        show
        expect(response).to have_http_status(:not_found)
      end
    end

    context 'when the request is requester_only' do
      let(:request_prominence) { 'requester_only' }

      it 'does not show the attachment to someone other than the requester' do
        other_user = FactoryBot.create(:user)
        sign_in other_user
        expect_signed_in_as(other_user)
        show
        expect(response).to have_http_status(:not_found)
      end

      it 'does not cache an attachment when showing an attachment to the ' \
         'requester' do
        sign_in info_request.user
        show
        expect_not_cached
      end

      it 'does not cache an attachment when showing an attachment to the ' \
         'admin' do
        sign_in FactoryBot.create(:admin_user)
        show
        expect_not_cached
      end
    end

    context 'when the incoming message has prominence hidden' do
      let(:message_prominence) { 'hidden' }

      it 'does not download attachments for a non-logged in user' do
        show
        expect(response).to have_http_status(:not_found)
      end

      it 'does not download attachments for the request owner' do
        sign_in info_request.user
        show
        expect_hidden('This message is not published')
      end

      it 'does not reveal the filename of a hidden reply' do
        sign_in info_request.user
        show(file_name: 'guessed-secret-name.txt')
        expect_hidden('This message is not published')
      end

      it 'downloads attachments for an admin user' do
        sign_in FactoryBot.create(:admin_user)
        show
        expect(response.media_type).to eq('text/plain')
        expect(response).to be_successful
      end

      it 'does not cache an attachment when showing an attachment to the ' \
         'requester' do
        sign_in info_request.user
        show
        expect(response).to have_http_status(:forbidden)
        expect(response.headers['Cache-Control']).to eq('private, no-store')
      end

      it 'does not cache an attachment when showing an attachment to the ' \
         'admin' do
        sign_in FactoryBot.create(:admin_user)
        show
        expect_not_cached
      end
    end

    context 'when the attachment has prominence hidden' do
      let(:attachment_prominence) { 'hidden' }

      it 'does not download attachments for a non-logged in user' do
        show
        expect(response).to have_http_status(:not_found)
      end

      it 'does not download attachments for the request owner' do
        sign_in info_request.user
        show
        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(incoming_message_path(message))
      end

      it 'gives the same response for a guessed hidden filename' do
        sign_in info_request.user
        show(file_name: 'guessed-secret-name.txt')
        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(incoming_message_path(message))
      end

      it 'does not select a visible file with the same name as a hidden one' do
        FactoryBot.create(:body_text, incoming_message: message,
                                      filename: attachment.filename,
                                      body: 'visible sibling')
        sign_in info_request.user
        show
        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(incoming_message_path(message))
      end

      it 'downloads attachments for an admin user' do
        sign_in FactoryBot.create(:admin_user)
        show
        expect(response.media_type).to eq('text/plain')
        expect(response).to be_successful
      end

      it 'does not cache an attachment when showing an attachment to the ' \
         'requester' do
        sign_in info_request.user
        show
        expect(response).to have_http_status(:see_other)
        expect(response.headers['Cache-Control']).to eq('private, no-store')
      end

      it 'does not cache an attachment when showing an attachment to the ' \
         'admin' do
        sign_in FactoryBot.create(:admin_user)
        show
        expect_not_cached
      end
    end

    context 'when the attachment has prominence requester_only' do
      let(:attachment_prominence) { 'requester_only' }

      it 'does not download attachments for a non-logged in user' do
        show
        expect(response).to have_http_status(:not_found)
      end

      it 'downloads attachments for the request owner' do
        sign_in info_request.user
        show
        expect(response.media_type).to eq('text/plain')
        expect(response).to be_successful
      end

      it 'downloads attachments for an admin user' do
        sign_in FactoryBot.create(:admin_user)
        show
        expect(response.media_type).to eq('text/plain')
        expect(response).to be_successful
      end
    end

    context 'when a censor rule redacts an attachment filename' do
      let(:attachment) do
        FactoryBot.create(:pdf_attachment, incoming_message: message)
      end

      it 'uses the redacted filename in the Content-Disposition header' do
        info_request.censor_rules.create!(
          text: 'interesting.pdf', replacement: 'REDACTED.pdf',
          last_edit_editor: 'unknown', last_edit_comment: 'none'
        )

        sign_in info_request.user
        show

        header = response.headers['Content-Disposition']
        expect(header).to include('REDACTED.pdf')
        expect(header).not_to include('interesting.pdf')
      end
    end

    context 'when attachment has been erased' do
      let(:info_request) { FactoryBot.create(:info_request_with_incoming) }
      let(:message) { info_request.incoming_messages.first }
      let(:attachment) do
        FactoryBot.create(:body_text,
                          incoming_message: message,
                          erased_at: Time.zone.now)
      end

      before { sign_in info_request.user }

      it 'shows the erased attachment page' do
        show
        expect(response.media_type).to eq('text/html')
        expect(page_title).to eq('Attachment has been erased')
        expect(response.body).
          to include('This attachment has been removed and is no longer ' \
                     'available.')
      end

      it 'prevents download' do
        show
        expect(response).not_to be_successful
        expect(page_title).to eq('Attachment has been erased')
        expect(response.headers['Content-Disposition']).to be_nil
      end
    end
  end
end
