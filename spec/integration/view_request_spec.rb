require 'spec_helper'
require 'integration/alaveteli_dsl'

RSpec.describe "When viewing requests" do
  before do
    @info_request = FactoryBot.create(:info_request)
    @requester = login(@info_request.user)
  end

  # rubocop:disable Layout/LineLength -- a description that spans lines
  it 'should not raise a routing error when making a json link for a request with an
       "action" querystring param' do
    # rubocop:enable Layout/LineLength
    using_session(@requester) do
      browse_request("#{@info_request.url_title}?action=add")
      expect(page.status_code).to eq(200)
    end
  end

  context "when a request is hidden by an admin" do
    it 'should not retain any cached attachments to be served up by the webserver' do
      admin = login(FactoryBot.create(:admin_user))

      info_request = FactoryBot.create(:info_request)
      owner = login(info_request.user)
      incoming_message = FactoryBot.create(
        :incoming_message, info_request: info_request
      )
      attachment = FactoryBot.create(
        :pdf_attachment, :unmasked, incoming_message: incoming_message
      )
      FactoryBot.create(
        :response_event,
        info_request: info_request,
        incoming_message: incoming_message
      )

      attachment_url = "/request/#{info_request.url_title}/response/" \
        "#{incoming_message.id}/attach/#{attachment.url_part_number}/" \
        "#{attachment.filename}"
      using_session(owner) { visit(attachment_url) }

      expect {
        # Twice: the reply's text job queues the job that suggests documents
        # from it, which would otherwise run after the hiding below.
        2.times { perform_enqueued_jobs }
        attachment.reload
      }.to change { attachment.masked? }.from(false).to(true)

      # Admin makes the incoming message requester only
      using_session(admin) do
        hide_incoming_message(incoming_message, 'hidden', 'boring')
      end

      expect {
        perform_enqueued_jobs
        attachment.reload
      }.to change { attachment.masked? }.from(true).to(false)
    end
  end

  context 'when a response has prominence "normal"' do
    before do
      @info_request = FactoryBot.create(:info_request_with_incoming)
    end

    it 'should show the message itself to the requester or an admin, and nothing to an unregistered user' do
      # unregistered
      unregistered = without_login
      using_session(unregistered) do
        browse_request(@info_request.url_title)
        expect(page.status_code).to eq(404)
      end

      # requester
      owner = login(@info_request.user)
      using_session(owner) do
        browse_request(@info_request.url_title)
        expect(page).to have_content("hereisthetext")
        expect(page).to have_no_content("This message has not been published.")
      end

      # admin
      admin_user = login(FactoryBot.create(:admin_user))
      using_session(admin_user) do
        browse_request(@info_request.url_title)
        expect(page).to have_content("hereisthetext")
        expect(page).
          to have_no_content("This message has prominence 'hidden'.")
      end
    end
  end

  context 'when a response has prominence "hidden"' do
    before do
      @info_request = FactoryBot.create(:info_request_with_incoming)
      message = @info_request.incoming_messages.first
      message.prominence = 'hidden'
      message.prominence_reason = 'It is too irritating.'
      message.save!
    end

    it 'should show a hidden notice, not the message, to the requester, ' \
       'the message itself to an
            admin, and nothing to an unregistered user' do
      # unregistered
      using_session(without_login) do
        browse_request(@info_request.url_title)
        expect(page.status_code).to eq(404)
      end

      # requester
      owner = login(@info_request.user)
      using_session(owner) do
        browse_request(@info_request.url_title)
        expect(page).to have_content("This message has not been published.")
        expect(page).to have_content("It is too irritating")
        expect(page).to have_no_content("hereisthetext")
      end

      # admin
      admin_user = login(FactoryBot.create(:admin_user))
      using_session(admin_user) do
        browse_request(@info_request.url_title)
        expect(page).to have_content('hereisthetext')
        expect(page).to have_content('This message has prominence "hidden".')
        expect(page).to have_content("It is too irritating.")
        expect(page).to have_content("You can only see it because you are " \
                                     "logged in as a super user.")
      end
    end
  end
end
