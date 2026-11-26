require 'spec_helper'
require 'integration/alaveteli_dsl'

RSpec.describe 'when handling incoming mail' do
  let(:info_request) { FactoryBot.create(:info_request) }
  let(:requester) { login(info_request.user) }

  it "receives incoming messages, puts them in the requester's daily summary, and shows them" do
    receive_incoming_mail('incoming-request-plain.eml',
                          to: info_request.incoming_email)
    expect(ActionMailer::Base.deliveries).to be_empty
    notification = info_request.user.notifications.last
    expect(notification).to be_daily
    expect(notification.info_request_event.incoming_message).
      to eq(info_request.incoming_messages.last)
    using_session(requester) do
      visit show_request_path info_request.url_title
      expect(page).to have_content("No way!")
    end
  end

  it "makes attachments available for download" do
    receive_incoming_mail('incoming-request-two-same-name.eml',
                          to: info_request.incoming_email)

    attachment_1_path = get_attachment_path(
      info_request.url_title,
      incoming_message_id: info_request.incoming_messages.first.id,
      part: 2,
      file_name: 'hello world.txt'
    )
    attachment_2_path = get_attachment_path(
      info_request.url_title,
      incoming_message_id: info_request.incoming_messages.first.id,
      part: 3,
      file_name: 'hello world.txt'
    )

    using_session(requester) do
      visit attachment_1_path
      visit attachment_2_path
      perform_enqueued_jobs

      visit attachment_1_path
      expect(page.response_headers['Content-Type']).
        to eq('text/plain; charset=utf-8')
      expect(page).to have_content "Second hello"

      visit attachment_2_path
      expect(page.response_headers['Content-Type']).
        to eq('text/plain; charset=utf-8')
      expect(page).to have_content "First hello"
    end
  end

  it "converts message body to UTF8" do
    receive_incoming_mail('iso8859_2_raw_email.eml',
                          to: info_request.incoming_email)
    using_session(requester) do
      visit show_request_path(info_request.url_title)
      expect(page).to have_content "tënde"
    end
  end

  it "redirects back to incoming message when the attachment can't be found" do
    receive_incoming_mail('incoming-request-two-same-name.eml',
                          to: info_request.incoming_email)
    # asking for an attachment by the wrong filename should result in
    # redirecting back to the incoming message
    using_session(requester) do
      visit get_attachment_path(
        info_request.url_title,
        incoming_message_id: info_request.incoming_messages.first.id,
        part: 2,
        file_name: 'hello world.txt.baz'
      )

      expect(page).to have_current_path(
        show_request_path(info_request.url_title), ignore_query: true
      )
    end
  end

  it "treats attachments with unknown extensions as binary" do
    receive_incoming_mail('incoming-request-attachment-unknown-extension.eml',
                          to: info_request.incoming_email)

    attachment_path = get_attachment_path(
      info_request.url_title,
      incoming_message_id: info_request.incoming_messages.first.id,
      part: 2,
      file_name: 'hello.qwglhm'
    )

    using_session(requester) do
      visit attachment_path
      perform_enqueued_jobs

      visit attachment_path
      expect(page.response_headers['Content-Type']).
        to eq("application/octet-stream")
      expect(page).to have_content "an unusual sort of file"
    end
  end

  it "extracts attachments in the background, not while receiving email" do
    receive_incoming_mail('incoming-request-plain.eml',
                          to: info_request.incoming_email)
    im = info_request.incoming_messages.first
    expect(im.foi_attachments).to be_empty

    # Reading the reply in the background parses it.
    perform_enqueued_jobs
    expect(im.foi_attachments.reload).not_to be_empty
  end

  it "extract attachments when inbound email contains an Excel spreadsheet" do
    mail = Mail.new(to: info_request.incoming_email) do
      body 'My excel spreadsheet'
      add_file 'gems/excel_analyzer/spec/fixtures/data.xlsx'
    end

    receive_incoming_mail(mail.to_s)
    perform_enqueued_jobs

    im = info_request.incoming_messages.first
    expect(im.foi_attachments).to_not be_empty
  end
end
