require 'spec_helper'

RSpec.describe RequestMailbox do
  describe '#process' do
    before(:each) do
      ActionMailer::Base.deliveries = []
    end

    it "should append it to the appropriate request" do
      ir = info_requests(:fancy_dog_request)
      expect(ir.incoming_messages.count).to eq(1) # in the fixture
      receive_incoming_mail('incoming-request-plain.eml',
                            to: ir.incoming_email)
      expect(ir.incoming_messages.count).to eq(2) # one more arrives
      expect(ir.info_request_events[-1].incoming_message_id).not_to be_nil

      deliveries = ActionMailer::Base.deliveries
      expect(deliveries.size).to eq(0)
      # to the user who sent fancy_dog_request, in their daily summary
      notification = users(:bob_smith_user).notifications.last
      expect(notification.info_request_event).
        to eq(ir.incoming_messages.last.response_event)
      expect(notification).to be_daily
      deliveries.clear
    end

    it "should append it to the appropriate request if there is only one guess of information request" do
      ir = info_requests(:fancy_dog_request)
      expect(ir.incoming_messages.count).to eq(1) # in the fixture
      receive_incoming_mail(
        'incoming-request-plain.eml',
        to: "request-#{ir.id}-#{ir.idhash}a@localhost"
      )
      expect(ir.incoming_messages.count).to eq(2) # one more arrives
      expect(ir.info_request_events[-1].incoming_message_id).not_to be_nil
      expect(ir.info_request_events[-2].params[:editor]).to eq("automatic")

      deliveries = ActionMailer::Base.deliveries
      expect(deliveries.size).to eq(0)
      # to the user who sent fancy_dog_request, in their daily summary
      notification = users(:bob_smith_user).notifications.last
      expect(notification.info_request_event).
        to eq(ir.incoming_messages.last.response_event)
      expect(notification).to be_daily
      deliveries.clear
    end

    it "should append the email to each exact request address, unless that request has already received the email" do
      ir = info_requests(:fancy_dog_request)
      inbound_email = <<~EML
        From: EMAIL_FROM
        To: EMAIL_TO
        Message-ID: abcdefg@example.com
        Subject: Basic Email

        Hello, World
      EML
      expect(ir.incoming_messages.count).to eq(1) # in the fixture
      receive_incoming_mail(
        inbound_email,
        to: ir.incoming_email
      )
      expect(ir.incoming_messages.count).to eq(2) # one more arrives
      # send the email again
      receive_incoming_mail(
        inbound_email,
        to: ir.incoming_email
      )
      # this shouldn't add to the number of incoming mails
      expect(ir.incoming_messages.count).to eq(2)
      # send an email with a new Message-ID
      inbound_email = <<~EML
        From: EMAIL_FROM
        To: EMAIL_TO
        Message-ID: ab@example.com
        Subject: Basic Email

        Hello, World
      EML
      receive_incoming_mail(
        inbound_email,
        to: ir.incoming_email
      )
      # this should add to the number of incoming mails
      expect(ir.incoming_messages.count).to eq(3)
    end

    it 'should append the email to every request matches, unless the requests has already received the email' do
      info_request_1 = FactoryBot.create(:info_request)
      info_request_2 = FactoryBot.create(:info_request)

      expect(info_request_1.incoming_messages.count).to eq(0)
      expect(info_request_2.incoming_messages.count).to eq(0)

      inbound_email = <<~EML
        From: EMAIL_FROM
        To: EMAIL_TO
        Message-ID: ab@example.com
        Subject: Basic Email

        Hello, World
      EML

      # send email to one request
      receive_incoming_mail(
        inbound_email,
        to: info_request_1.incoming_email
      )

      expect(info_request_1.incoming_messages.count).to eq(1)
      expect(info_request_2.incoming_messages.count).to eq(0)

      # send same email to both requests, should only be delivered to the
      # request which hasn't already received the email
      receive_incoming_mail(
        inbound_email,
        to: [
          info_request_1.incoming_email,
          info_request_2.incoming_email
        ].join(', ')
      )

      expect(info_request_1.incoming_messages.count).to eq(1)
      expect(info_request_2.incoming_messages.count).to eq(1)
    end

    it "should store mail in holding pen and send to admin when the email is not to any information request" do
      ir = info_requests(:fancy_dog_request)
      expect(ir.incoming_messages.count).to eq(1)
      expect(InfoRequest.holding_pen_request.incoming_messages.count).to eq(0)
      receive_incoming_mail('incoming-request-plain.eml',
                            to: 'dummy@localhost')
      expect(ir.incoming_messages.count).to eq(1)
      expect(InfoRequest.holding_pen_request.incoming_messages.count).to eq(1)
      last_event = InfoRequest.holding_pen_request.info_request_events.last
      expect(last_event.params[:rejected_reason]).
        to eq("Could not identify the request from the email address")

      deliveries = ActionMailer::Base.deliveries
      expect(deliveries.size).to eq(1)
      mail = deliveries[0]
      expect(mail.to).to eq([AlaveteliConfiguration.contact_email])
      deliveries.clear
    end

    it "puts messages with a malformed To: in the holding pen" do
      FactoryBot.create(:info_request)
      receive_incoming_mail('incoming-request-plain.eml', to: 'asdfg')
      expect(InfoRequest.holding_pen_request.incoming_messages.count).to eq(1)
    end

    it "attaches messages with an info request address in the Received headers to the appropriate request" do
      ir = info_requests(:fancy_dog_request)
      expect(ir.incoming_messages.count).to eq(1) # in the fixture
      mail_content = <<~EOF
        From: "FOI Person" <foiperson@localhost>
        Received: from smtp-out.localhost
                by example.net with esmtps
                (Exim 4.89)
                (envelope-from <foiperson@localhost.co>)
                id ABC
                for #{ir.incoming_email}.com; Mon, 23 Nov 2020 00:00:00 +0000
        Test
      EOF
      receive_incoming_mail(mail_content)
      expect(ir.incoming_messages.count).to eq(2) # one more arrives
      expect(ir.info_request_events[-1].incoming_message_id).not_to be_nil

      deliveries = ActionMailer::Base.deliveries
      expect(deliveries.size).to eq(0)
      # to the user who sent fancy_dog_request, in their daily summary
      notification = users(:bob_smith_user).notifications.last
      expect(notification.info_request_event).
        to eq(ir.incoming_messages.last.response_event)
      expect(notification).to be_daily
      deliveries.clear
    end

    it "should parse attachments from mails sent with apple mail" do
      ir = info_requests(:fancy_dog_request)
      expect(ir.incoming_messages.count).to eq(1)
      expect(InfoRequest.holding_pen_request.incoming_messages.count).to eq(0)
      receive_incoming_mail('apple-mail-with-attachments.eml',
                            to: 'dummy@localhost')
      expect(ir.incoming_messages.count).to eq(1)
      expect(InfoRequest.holding_pen_request.incoming_messages.count).to eq(1)
      last_event = InfoRequest.holding_pen_request.info_request_events.last
      expect(last_event.params[:rejected_reason]).
        to eq("Could not identify the request from the email address")

      im = IncomingMessage.last
      # Check that the attachments haven't been somehow loaded from a
      # previous test run
      expect(im.foi_attachments.size).to eq(0)

      # Trace where attachments first get loaded:
      # TODO: Ideally this should be 3, but some html parts from Apple Mail
      # are being treated like attachments
      im.extract_attachments!
      expect(im.foi_attachments.size).to eq(6)

      # Clean up
      deliveries = ActionMailer::Base.deliveries
      expect(deliveries.size).to eq(1)
      mail = deliveries[0]
      expect(mail.to).to eq([AlaveteliConfiguration.contact_email])
      deliveries.clear
    end

    it "should store mail in holding pen and send to admin when the from email is empty and only authorities can reply" do
      ir = info_requests(:fancy_dog_request)
      ir.allow_new_responses_from = 'authority_only'
      ir.handle_rejected_responses = 'holding_pen'
      ir.save!
      expect(ir.incoming_messages.count).to eq(1)
      expect(InfoRequest.holding_pen_request.incoming_messages.count).to eq(0)
      receive_incoming_mail('incoming-request-plain.eml',
                             to: ir.incoming_email,
                             from: "")
      expect(ir.incoming_messages.count).to eq(1)
      expect(InfoRequest.holding_pen_request.incoming_messages.count).to eq(1)
      last_event = InfoRequest.holding_pen_request.info_request_events.last
      expect(last_event.params[:rejected_reason]).
        to match(/there is no "From" address/)

      deliveries = ActionMailer::Base.deliveries
      expect(deliveries.size).to eq(1)
      mail = deliveries[0]
      expect(mail.to).to eq([AlaveteliConfiguration.contact_email])
      deliveries.clear
    end

    it "should store mail in holding pen and send to admin when the from email is unknown and only authorities can reply" do
      ir = info_requests(:fancy_dog_request)
      ir.allow_new_responses_from = 'authority_only'
      ir.handle_rejected_responses = 'holding_pen'
      ir.save!
      expect(ir.incoming_messages.count).to eq(1)
      expect(InfoRequest.holding_pen_request.incoming_messages.count).to eq(0)
      receive_incoming_mail('incoming-request-plain.eml',
                            to: ir.incoming_email,
                            from: "frob@nowhere.com")
      expect(ir.incoming_messages.count).to eq(1)
      expect(InfoRequest.holding_pen_request.incoming_messages.count).to eq(1)
      last_event = InfoRequest.holding_pen_request.info_request_events.last
      expect(last_event.params[:rejected_reason]).
        to match(/Only the authority can reply/)

      deliveries = ActionMailer::Base.deliveries
      expect(deliveries.size).to eq(1)
      mail = deliveries[0]
      expect(mail.to).to eq([AlaveteliConfiguration.contact_email])
      deliveries.clear
    end

    context "when sent from known spam address" do
      before do
        @spam_address = FactoryBot.create(:spam_address)
      end

      it "recognises a spam address under the 'To' header" do
        receive_incoming_mail('incoming-request-plain.eml',
                              to: @spam_address.email)

        deliveries = ActionMailer::Base.deliveries
        expect(deliveries.size).to eq(0)
        deliveries.clear
      end

      it "recognises a spam address under the 'CC' header" do
        receive_incoming_mail('incoming-request-plain.eml',
                              cc: @spam_address.email)

        deliveries = ActionMailer::Base.deliveries
        expect(deliveries.size).to eq(0)
        deliveries.clear
      end

      it "recognises a spam address under the 'BCC' header" do
        receive_incoming_mail('incoming-request-plain.eml',
                              bcc: @spam_address.email)

        deliveries = ActionMailer::Base.deliveries
        expect(deliveries.size).to eq(0)
        deliveries.clear
      end

      it "recognises a spam email address under the 'envelope-to' header" do
        receive_incoming_mail('incoming-request-plain.eml',
                              envelope_to: @spam_address.email)

        deliveries = ActionMailer::Base.deliveries
        expect(deliveries.size).to eq(0)
        deliveries.clear
      end
    end

    it "should send a notice to sender when a request is stopped
        fully for spam" do
      # mark request as anti-spam
      ir = info_requests(:fancy_dog_request)
      ir.allow_new_responses_from = 'nobody'
      ir.handle_rejected_responses = 'bounce'
      ir.save!

      # test what happens if something arrives
      expect(ir.incoming_messages.count).to eq(1) # in the fixture
      receive_incoming_mail('incoming-request-plain.eml',
                            to: ir.incoming_email)
      expect(ir.incoming_messages.count).to eq(1) # nothing should arrive

      # should be a message back to sender
      deliveries = ActionMailer::Base.deliveries
      expect(deliveries.size).to eq(1)
      mail = deliveries[0]
      expect(mail.to).to eq(['geraldinequango@localhost'])
      expect(mail.multipart?).to eq(false)
      expect(mail.body).to include("marked to no longer receive responses")
      deliveries.clear
    end

    it "should return incoming mail to sender if not authority when a request is stopped for non-authority spam" do
      # mark request as anti-spam
      ir = info_requests(:fancy_dog_request)
      ir.allow_new_responses_from = 'authority_only'
      ir.handle_rejected_responses = 'bounce'
      ir.save!

      # Test what happens if something arrives from authority domain
      # (@localhost)
      expect(ir.incoming_messages.count).to eq(1) # in the fixture
      receive_incoming_mail('incoming-request-plain.eml',
                            to: ir.incoming_email,
                            from: "Geraldine <geraldinequango@localhost>")
      expect(ir.incoming_messages.count).to eq(2) # one more arrives

      # ... the original requester is told in their daily summary
      deliveries = ActionMailer::Base.deliveries
      expect(deliveries.size).to eq(0)
      # the user who sent fancy_dog_request
      notification = users(:bob_smith_user).notifications.last
      expect(notification.info_request_event).
        to eq(ir.incoming_messages.last.response_event)
      expect(notification).to be_daily
      deliveries.clear

      # Test what happens if something arrives from another domain
      expect(ir.incoming_messages.count).to eq(2) # in fixture and above
      receive_incoming_mail('incoming-request-plain.eml',
                            to: ir.incoming_email,
                            from: "dummy-address@dummy.localhost")
      expect(ir.incoming_messages.count).to eq(2) # nothing should arrive

      # ... should be a bounce message back to sender
      deliveries = ActionMailer::Base.deliveries
      expect(deliveries.size).to eq(1)
      mail = deliveries[0]
      expect(mail.to).to eq(['dummy-address@dummy.localhost'])
      deliveries.clear
    end

    it "discards rejected responses with a malformed From: when set to bounce" do
      ir = info_requests(:fancy_dog_request)
      ir.allow_new_responses_from = 'nobody'
      ir.handle_rejected_responses = 'bounce'
      ir.save!
      expect(ir.incoming_messages.count).to eq(1)

      receive_incoming_mail('incoming-request-plain.eml',
                            to: ir.incoming_email,
                            from: "")
      expect(ir.incoming_messages.count).to eq(1)

      deliveries = ActionMailer::Base.deliveries
      expect(deliveries.size).to eq(0)
      deliveries.clear
    end

    it "should send all new responses to holding pen if a request is marked to do so" do
      # mark request as anti-spam
      ir = info_requests(:fancy_dog_request)
      ir.allow_new_responses_from = 'nobody'
      ir.handle_rejected_responses = 'holding_pen'
      ir.save!

      # test what happens if something arrives
      ir = info_requests(:fancy_dog_request)
      expect(ir.incoming_messages.count).to eq(1)
      expect(InfoRequest.holding_pen_request.incoming_messages.count).to eq(0)
      receive_incoming_mail('incoming-request-plain.eml',
                            to: ir.incoming_email)
      expect(ir.incoming_messages.count).to eq(1)

      # arrives in holding pen
      expect(InfoRequest.holding_pen_request.incoming_messages.count).to eq(1)
      last_event = InfoRequest.holding_pen_request.info_request_events.last
      expect(last_event.params[:rejected_reason]).
        to match(/allow new responses from nobody/)

      # should be a message to admin regarding holding pen
      deliveries = ActionMailer::Base.deliveries
      expect(deliveries.size).to eq(1)
      mail = deliveries[0]
      expect(mail.to).to eq([AlaveteliConfiguration.contact_email])
      deliveries.clear
    end

    it "should destroy the messages sent to a request if marked to do so" do
      ActionMailer::Base.deliveries.clear
      # mark request as anti-spam
      ir = info_requests(:fancy_dog_request)
      ir.allow_new_responses_from = 'nobody'
      ir.handle_rejected_responses = 'blackhole'
      ir.save!

      # test what happens if something arrives - should be nothing
      ir = info_requests(:fancy_dog_request)
      expect(ir.incoming_messages.count).to eq(1)
      expect(InfoRequest.holding_pen_request.incoming_messages.count).to eq(0)
      receive_incoming_mail('incoming-request-plain.eml',
                            to: ir.incoming_email)
      expect(ir.incoming_messages.count).to eq(1)
      expect(InfoRequest.holding_pen_request.incoming_messages.count).to eq(0)

      # should be no messages to anyone
      deliveries = ActionMailer::Base.deliveries
      expect(deliveries.size).to eq(0)
    end

    it 'stores message_id and message_checksum on the raw_email' do
      ir = FactoryBot.create(:info_request)
      receive_incoming_mail('incoming-request-plain.eml', to: ir.incoming_email)
      raw_email = ir.reload.incoming_messages.last.raw_email
      expect(raw_email[:message_id]).to be_present
      expect(raw_email[:message_checksum]).to be_present
    end
  end

  describe 'when a request turns mail away to the holding pen' do
    let(:request) do
      FactoryBot.create(:info_request,
                        allow_new_responses_from: 'nobody',
                        handle_rejected_responses: 'holding_pen')
    end

    let(:holding_pen) { InfoRequest.holding_pen_request }

    def deliver(body)
      receive_incoming_mail(<<~EML, to: request.incoming_email)
        From: EMAIL_FROM
        To: EMAIL_TO
        Message-ID: <again@sender.example>
        Subject: Basic Email

        #{body}
      EML
    end

    # The holding pen has the first copy, so it records nothing for the
    # second. That must not read as the request accepting the mail.
    it 'turns away a second mail with the same Message-ID too' do
      deliver('Hello')
      deliver('Hello again')

      expect(request.incoming_messages.count).to eq(0)
      expect(request.reload.rejected_incoming_count).to eq(2)
      expect(holding_pen.incoming_messages.count).to eq(1)
    end
  end

  describe 'when an earlier reply was erased with no message id stored' do
    let(:request) { FactoryBot.create(:info_request) }

    before do
      earlier = FactoryBot.create(:incoming_message, info_request: request)
      earlier.raw_email.file.purge
      earlier.raw_email.update_columns(
        message_id: nil, message_checksum: nil, erased_at: Time.zone.now
      )
    end

    { 'with a Message-ID' => "Message-ID: <new@sender.example>\n",
      'with no Message-ID' => '' }.each do |what, header|
      it "receives new mail #{what}" do
        mail = "From: EMAIL_FROM\nTo: EMAIL_TO\n#{header}" \
               "Subject: New\n\nHello\n"

        expect { receive_incoming_mail(mail, to: request.incoming_email) }.
          to change { request.incoming_messages.count }.by(1)
      end
    end
  end

  describe 'when no mail can be read past its header lines' do
    let(:request) { FactoryBot.create(:info_request) }
    let(:holding_pen) { InfoRequest.holding_pen_request }
    let(:inbound_email) { ActionMailbox::InboundEmail.order(:id).last }

    before do
      allow(MailHandler).to receive(:get_attachment_attributes).
        and_raise(MailHandler::ReadRefused, 'refused')
    end

    def deliver(to:, from: 'records@authority.example')
      receive_incoming_mail('incoming-request-plain.eml', to: to, from: from)
    end

    shared_examples 'mail dealt with on arrival' do
      it 'reads no parts and leaves nothing waiting' do
        expect { delivery }.
          not_to have_enqueued_job(ActionMailbox::RoutingJob)
        expect(MailHandler).not_to have_received(:get_attachment_attributes)
        expect(inbound_email).to be_delivered
      end
    end

    context 'with mail to a request whose requester is emailed at once' do
      let(:request) do
        FactoryBot.create(:info_request, use_notifications: false)
      end

      let(:delivery) { deliver(to: request.incoming_email) }

      before do
        allow(IncomingAttention::Effective).to receive(:active?).
          and_return(false)
      end

      include_examples 'mail dealt with on arrival'

      it 'records the reply and emails the requester' do
        expect { delivery }.
          to change { request.incoming_messages.count }.by(1).
          and change { ActionMailer::Base.deliveries.size }.by(1)
      end
    end

    context 'with mail to a request whose requester gets a notification' do
      let(:request) { FactoryBot.create(:use_notifications_request) }
      let(:delivery) { deliver(to: request.incoming_email) }

      include_examples 'mail dealt with on arrival'

      it 'records the reply and the notification' do
        expect { delivery }.
          to change { request.incoming_messages.count }.by(1).
          and change { request.user.notifications.count }.by(1)
      end
    end

    context 'with mail to an address one request is guessed from' do
      let(:delivery) do
        deliver(to: "request-#{request.id}-#{request.idhash}a@localhost")
      end

      include_examples 'mail dealt with on arrival'

      it 'records the reply' do
        expect { delivery }.to change { request.incoming_messages.count }.by(1)
      end
    end

    context 'with mail to no request' do
      let(:delivery) { deliver(to: 'nobody-here@localhost') }

      include_examples 'mail dealt with on arrival'

      it 'records it in the holding pen' do
        expect { delivery }.
          to change { holding_pen.incoming_messages.count }.by(1)
      end
    end

    context 'with an earlier reply not yet parsed, to a request that ' \
            'takes replies from the authority only' do
      before do
        deliver(to: request.incoming_email, from: 'first@replier.example')
        request.update!(allow_new_responses_from: 'authority_only',
                        handle_rejected_responses: 'holding_pen')
      end

      context 'when the sender shares the earlier reply\'s domain' do
        let(:delivery) do
          deliver(to: request.incoming_email, from: 'second@replier.example')
        end

        include_examples 'mail dealt with on arrival'

        it 'records the reply, with the earlier one still unparsed' do
          expect { delivery }.
            to change { request.incoming_messages.count }.by(1)
          expect(request.incoming_messages.pluck(:last_parsed)).
            to eq([nil, nil])
        end
      end

      context 'when the sender is from somewhere else' do
        let(:delivery) do
          deliver(to: request.incoming_email, from: 'someone@other.example')
        end

        include_examples 'mail dealt with on arrival'

        it 'records it in the holding pen' do
          expect { delivery }.
            to change { holding_pen.incoming_messages.count }.by(1)
          expect(request.incoming_messages.count).to eq(1)
        end
      end
    end

    context 'with an earlier reply that has no header values stored, to a ' \
            'request that takes replies from the authority only' do
      let(:delivery) do
        deliver(to: request.incoming_email, from: 'second@replier.example')
      end

      before do
        earlier = FactoryBot.create(:incoming_message, :unparsed,
                                    info_request: request)
        earlier.raw_email.data = +"From: first@replier.example\n\nHello\n"
        earlier.raw_email.save!
        request.update!(allow_new_responses_from: 'authority_only',
                        handle_rejected_responses: 'holding_pen')
      end

      include_examples 'mail dealt with on arrival'

      it 'records the reply' do
        expect { delivery }.to change { request.incoming_messages.count }.by(1)
      end
    end

    context 'with mail to a request that takes no replies' do
      let(:delivery) { deliver(to: request.incoming_email) }

      before do
        request.update!(allow_new_responses_from: 'nobody',
                        handle_rejected_responses: 'bounce')
      end

      it 'reads no parts, turns it away and leaves nothing waiting' do
        expect { delivery }.
          not_to have_enqueued_job(ActionMailbox::RoutingJob)
        expect(MailHandler).not_to have_received(:get_attachment_attributes)
        expect(request.incoming_messages.count).to eq(0)
        expect(inbound_email).to be_delivered
      end
    end
  end

  describe 'when a read is refused while mail is routed' do
    let(:first) { FactoryBot.create(:info_request) }
    let(:second) { FactoryBot.create(:info_request) }
    let(:refusing) { [second] }
    let(:inbound_email) { ActionMailbox::InboundEmail.order(:id).last }

    let(:delivery) do
      receive_incoming_mail(
        mail, to: [first, second].map(&:incoming_email).join(', ')
      )
    end

    let(:mail) do
      <<~EML
        From: EMAIL_FROM
        To: EMAIL_TO
        Message-ID: <waiting@authority.example>
        Subject: Basic Email

        Hello, World
      EML
    end

    before do
      allow(InfoRequest::ResponseGatekeeper).
        to receive(:for).and_wrap_original do |original, mode, request|
          if refusing.include?(request)
            raise MailHandler::ReadRefused, 'refused'
          end

          original.call(mode, request)
        end
    end

    it 'puts the mail back to waiting and queues its routing again' do
      expect { delivery }.
        to have_enqueued_job(ActionMailbox::RoutingJob).
        at(a_value_within(1.minute).of(10.minutes.from_now))
      expect(inbound_email).to be_pending
      expect(first.incoming_messages.count).to eq(1)
      expect(second.incoming_messages.count).to eq(0)
    end

    it 'records the mail once for each request when it is routed again' do
      delivery
      refusing.clear
      inbound_email.route

      expect(inbound_email.reload).to be_delivered
      expect(first.incoming_messages.count).to eq(1)
      expect(second.incoming_messages.count).to eq(1)
    end

    context 'when the mail has no Message-ID header' do
      let(:mail) do
        <<~EML
          From: EMAIL_FROM
          To: EMAIL_TO
          Subject: Basic Email

          Hello, World
        EML
      end

      it 'records the mail once for each request when it is routed again' do
        delivery
        refusing.clear
        inbound_email.route

        expect(first.incoming_messages.count).to eq(1)
        expect(second.incoming_messages.count).to eq(1)
      end
    end

    context 'when the mail has waited as long as it may' do
      before do
        allow(AlaveteliConfiguration).to receive_messages(
          exception_notifications_from: 'errors@localhost',
          exception_notifications_to: 'admin@localhost'
        )
        allow(ExceptionNotifier).to receive(:notify_exception)
        delivery
        inbound_email.update_columns(created_at: 13.hours.ago)
      end

      it 'leaves it as failed and sends one exception notification' do
        expect { inbound_email.route }.
          not_to have_enqueued_job(ActionMailbox::RoutingJob)
        expect(inbound_email.reload).to be_failed
        expect(ExceptionNotifier).to have_received(:notify_exception).once.
          with(an_instance_of(MailHandler::ReadRefused),
               data: { inbound_email_id: inbound_email.id })
      end
    end

    context 'when the first request had turned the mail away' do
      let(:holding_pen) { InfoRequest.holding_pen_request }

      before do
        first.update!(allow_new_responses_from: 'nobody',
                      handle_rejected_responses: 'holding_pen')
        delivery
        refusing.clear
        inbound_email.route
      end

      it 'still turns it away when it is routed again' do
        expect(first.incoming_messages.count).to eq(0)
        expect(second.incoming_messages.count).to eq(1)
        expect(holding_pen.incoming_messages.count).to eq(1)
      end

      context 'when the mail has no Message-ID header' do
        let(:mail) do
          <<~EML
            From: EMAIL_FROM
            To: EMAIL_TO
            Subject: Basic Email

            Hello, World
          EML
        end

        it 'still turns it away, and the holding pen keeps one copy' do
          expect(first.incoming_messages.count).to eq(0)
          expect(second.incoming_messages.count).to eq(1)
          expect(holding_pen.incoming_messages.count).to eq(1)
        end
      end
    end

    it 'leaves the mail as failed when its routing cannot be queued' do
      allow(ActionMailbox::RoutingJob).to receive(:set).and_return(
        class_double(ActionMailbox::RoutingJob, perform_later: false)
      )

      expect { delivery }.to raise_error(MailHandler::ReadRefused)
      expect(inbound_email).to be_failed
    end

    it 'leaves other errors to fail the mail' do
      allow(InfoRequest::ResponseGatekeeper).
        to receive(:for).and_raise(IOError, 'storage')

      expect { delivery }.to raise_error(IOError)
      expect(inbound_email).to be_failed
    end
  end
end
