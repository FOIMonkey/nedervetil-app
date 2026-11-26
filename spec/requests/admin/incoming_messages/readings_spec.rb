require 'spec_helper'

RSpec.describe 'Admin incoming message readings and raw email downloads',
               type: :request do
  let(:admin) { users(:admin_user) }
  let(:info_request) { FactoryBot.create(:info_request) }
  let(:incoming_message) do
    mail = Mail.from_source(
      "From: authority@example.org\r\nTo: #{info_request.incoming_email}\r\n" \
      "Subject: Reply\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n" \
      'Original reply text'
    )
    msg = info_request.receive(mail)
    IncomingMessage::StoreTextJob.perform_now(msg)
    msg.reload
  end

  before { sign_in admin }

  it 're-reads the email and allows .eml download while kept' do
    get admin_raw_email_path(incoming_message.raw_email, format: :eml)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Original reply text')

    post admin_incoming_message_reading_path(incoming_message)
    expect(response).
      to redirect_to(edit_admin_incoming_message_path(incoming_message))
    expect(flash[:notice]).to eq('The email has been read again.')
  end

  it 'stops .eml downloads and read-again after the raw email expires' do
    raw_email = incoming_message.raw_email
    raw_email.file.purge

    get admin_raw_email_path(raw_email, format: :eml)
    expect(response).to have_http_status(:not_found)

    get admin_raw_email_path(raw_email)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('no longer kept')

    post admin_incoming_message_reading_path(incoming_message)
    expect(response).
      to redirect_to(edit_admin_incoming_message_path(incoming_message))
    expect(flash[:error]).to include('no longer kept')
  end

  it 'preserves manual_black_mask attachments on read-again and clears stale rasterized metadata' do
    part = incoming_message.get_main_body_text_part
    part.replace_file!('[redacted] manually')
    part.update!(black_masked: true)
    part.file_blob.update!(
      metadata: part.file_blob.metadata.merge('manual_black_mask' => true)
    )

    post admin_incoming_message_reading_path(incoming_message)
    expect(part.reload.body).to eq('[redacted] manually')
    expect(part).to be_black_masked

    part.file_blob.update!(
      metadata: part.file_blob.metadata.except('manual_black_mask').
        merge('rasterized' => true)
    )
    part.remask_from_email!
    expect(part.reload.file_blob.metadata['rasterized']).to be_nil

    part.file_blob.update!(
      metadata: part.file_blob.metadata.merge('rasterized' => true)
    )
    post admin_incoming_message_reading_path(incoming_message)
    expect(part.reload.file_blob.metadata['rasterized']).to be_nil
  end
end
