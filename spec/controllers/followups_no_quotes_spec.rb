require 'spec_helper'

# FollowupsController intentionally skips :read checks on the reply so hiding
# an incoming message does not block the requester from following up.
RSpec.describe FollowupsController, type: :controller do
  render_views

  let(:owner) { FactoryBot.create(:user) }
  let(:request_record) { FactoryBot.create(:info_request, user: owner) }

  def reply_with(prominence)
    incoming = AttachmentFixtures.deliver(
      request_record, [], text: "Original reply content token.\n"
    )
    reason = 'Synthetic' unless prominence == 'normal'
    incoming.update!(prominence: prominence, prominence_reason: reason,
                     subject: 'Distinctive reply subject token',
                     from_name: 'Response Officer',
                     from_email: 'officer@example.test',
                     valid_to_reply_to: true)
    incoming
  end

  def hidden_parts
    ['Original reply content token', 'Distinctive reply subject token',
     'Response Officer', 'officer@example.test']
  end

  def follow_up(incoming)
    ActionMailer::Base.deliveries.clear
    post :create, params: {
      request_url_title: request_record.url_title,
      incoming_message_id: incoming.id,
      outgoing_message: { letter: 'Please provide the remaining information.',
                          what_doing: 'normal_sort' }
    }
    expect(response).to have_http_status(:found)
    expect(ActionMailer::Base.deliveries.size).to eq(1)
    ActionMailer::Base.deliveries.last
  end

  it 'opens the follow-up form for a hidden reply, showing nothing of it' do
    incoming = reply_with('hidden')
    expect(Ability.new(owner).can?(:read, incoming)).to be(false)
    sign_in(owner)

    get :new, params: { request_url_title: request_record.url_title,
                        incoming_message_id: incoming.id }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('outgoing_message')
    expect(response.body).to include(request_record.public_body.name)
    expect(response.body).not_to include(*hidden_parts)
  end

  it 'previews a follow-up to a hidden reply, addressed to the authority' do
    incoming = reply_with('hidden')
    sign_in(owner)

    post :preview, params: {
      request_url_title: request_record.url_title,
      incoming_message_id: incoming.id,
      outgoing_message: { letter: 'Please provide the remaining information.',
                          what_doing: 'normal_sort' }
    }

    expect(response).to have_http_status(:ok)
    page = Capybara.string(response.body)
    expect(page.find('.preview_subject').text).
      to include(request_record.public_body.name, 'Subject:')
    expect(response.body).
      to include('Please provide the remaining information.')
    expect(response.body).not_to include(*hidden_parts)
  end

  it 'sends a follow-up to a hidden reply to the main FOI address, ' \
     'without quoting it' do
    incoming = reply_with('hidden')
    sign_in(owner)

    mail = follow_up(incoming)

    outgoing = request_record.outgoing_messages.order(:id).last
    expect(outgoing.incoming_message_followup_id).to eq(incoming.id)
    expect(outgoing.status).to eq('sent')
    expect(mail.to).to eq([request_record.recipient_email])
    expect(mail[:to].to_s).to eq(request_record.recipient_name_and_email)
    expect([mail[:to].to_s, mail.subject, mail.body.decoded].join("\n")).
      not_to include(*hidden_parts)
    expect(mail.body.decoded.strip).to eq(outgoing.body.strip)
  end

  %w[normal].each do |prominence|
    it "sends a follow-up to a #{prominence} reply to its sender, " \
       'without quoting it' do
      incoming = reply_with(prominence)
      expect(Ability.new(owner).can?(:read, incoming)).to be(true)
      sign_in(owner)

      mail = follow_up(incoming)

      expect(mail.to).to eq(['officer@example.test'])
      expect(mail.subject).to include('Distinctive reply subject token')
      expect(mail.body.decoded).
        not_to include('-----Original Message-----',
                       'Original reply content token')
    end
  end

  # Routing depends on the reply alone (e.g. admin resend for a banned user).
  it "resends a banned requester's follow-up to a normal reply to its sender" do
    incoming = reply_with('normal')
    sign_in(owner)
    follow_up(incoming)
    outgoing = request_record.outgoing_messages.order(:id).last
    owner.update!(ban_text: 'Synthetic ban')

    ActionMailer::Base.deliveries.clear
    OutgoingMailer.followup(request_record.reload, outgoing.reload,
                            outgoing.incoming_message_followup).deliver_now

    mail = ActionMailer::Base.deliveries.last
    expect(mail.to).to eq(['officer@example.test'])
    expect(mail.subject).to include('Distinctive reply subject token')
  end
end
