require 'spec_helper'

RSpec.describe 'Replies whose main body can’t be built' do
  include DisclosuresHelpers
  include_context 'with production error pages'

  unless defined?(NOTE)
    NOTE = 'We were not able to process this message.'.freeze
  end

  let(:owner) { FactoryBot.create(:user) }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:info_request) { FactoryBot.create(:info_request, user: owner) }
  let(:page) { "/request/#{info_request.url_title}" }

  def reply(body, content_type)
    mail = Mail.new
    mail.from = info_request.public_body.request_email
    mail.to = info_request.incoming_email
    mail.subject = "RE: Freedom of Information request - #{info_request.title}"
    mail.message_id = "<#{SecureRandom.hex(10)}@synthetic.test>"
    mail.content_type = "#{content_type}; charset=UTF-8"
    mail.body = body
    message = info_request.receive(Mail.from_source(mail.encoded))
    IncomingMessage.find(message.id).tap(&:parse_raw_email)
  end

  def nested_html(depth)
    "<html><body>#{'<div class="n">' * depth}Deep reply text" \
      "#{'</div>' * depth}</body></html>"
  end

  def stored(message)
    IncomingMessage.where(id: message.id).pick(:cached_main_body_text_folded)
  end

  def builds_during
    count = 0
    allow_any_instance_of(IncomingMessage).
      to receive(:get_main_body_text_internal).
      and_wrap_original do |original, *args|
      count += 1
      original.call(*args)
    end
    yield
    count
  end

  def view_twice_storing_the_note(message)
    sign_in(owner)
    get page
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(NOTE)
    expect(stored(message)).to include(NOTE)

    expect(builds_during { get page }).to eq(0)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(NOTE)
  end

  it 'stores the note for HTML nested past the parser’s depth limit' do
    message = reply(nested_html(450), 'text/html')
    expect(stored(message)).to be_nil

    view_twice_storing_the_note(message)

    get "/request/#{info_request.url_title}/followups/new/#{message.id}"
    expect(response).to have_http_status(:ok)
    sign_in(admin)
    get page
    expect(response).to have_http_status(:ok)
    get "/admin/requests/#{info_request.id}"
    expect(response).to have_http_status(:ok)
  end

  it 'holds a reply with too many MIME parts without failing on later reads' do
    boundary = 'synthetic-many-parts'
    parts = (1..1_001).map do |number|
      "--#{boundary}\r\nContent-Type: text/plain\r\n\r\npart #{number}\r\n"
    end.join
    raw = "From: authority@example.org\r\n" \
          "To: #{info_request.incoming_email}\r\n" \
          "Subject: Synthetic reply\r\nMIME-Version: 1.0\r\n" \
          "Content-Type: multipart/mixed; boundary=\"#{boundary}\"\r\n\r\n" \
          "#{parts}--#{boundary}--\r\n"
    message = info_request.receive(Mail.from_source(raw))

    sign_in(owner)
    get page
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(
      'We could not process this message. Please contact us.'
    )
    expect(response.body).not_to include('part 1001')
    expect(message.reload.prominence).to eq('hidden')
    expect(message.last_parsed).not_to be_nil
    expect(message.raw_email.file).to be_attached
    expect(IncomingAttention::Input.available?(message)).to be(false)

    holds = info_request.info_request_events.where(event_type: 'edit_incoming')
    expect(holds.count).to eq(1)
    expect(holds.first.params[:incoming_message]).to eq(message)
    expect(holds.first.params).to include(
      old_prominence: 'normal',
      prominence: 'hidden',
      reason: 'Mail not processed: mail part limit exceeded'
    )

    message.update!(prominence_reason: 'Manual reason')
    message.parse_raw_email!
    expect(message.reload.prominence_reason).to eq('Manual reason')
    expect(holds.count).to eq(1)

    expect(MailHandler).not_to receive(:get_attachment_attributes)
    get page
    expect(response).to have_http_status(:ok)
    sign_in(admin)
    get "/admin/requests/#{info_request.id}"
    expect(response).to have_http_status(:ok)
  end

  it 'still builds HTML nested within the limit' do
    message = reply(nested_html(390), 'text/html')
    sign_in(owner)
    get page
    expect(response).to have_http_status(:ok)
    expect(stored(message)).to include('Deep reply text')
  end

  it 'stores the note for main-body text over 1 MB' do
    message = reply(
      "Reply text line with ordinary words in it here.\n" * 21_500,
      'text/plain'
    )
    view_twice_storing_the_note(message)
  end

  it 'stores the note when a regexp times out' do
    message = reply("Dear requester,\nOur reply is attached.\n", 'text/plain')
    allow(IncomingMessage).
      to receive(:remove_quoted_sections).and_raise(Regexp::TimeoutError)
    view_twice_storing_the_note(message)
  end

  it 'shows the note without storing it while converters are refused, then the text once they work' do
    allow(AlaveteliSandbox).to receive(:disabled?).and_return(true)
    message = reply('<html><body><p>Dear requester,</p>' \
                    '<p>Our reply is attached.</p></body></html>',
                    'text/html')
    sign_in(owner)
    2.times do
      expect(builds_during { get page }).to be >= 1
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(NOTE)
      expect(stored(message)).to be_nil
    end

    allow(AlaveteliSandbox).to receive(:disabled?).and_call_original
    get page
    expect(response).to have_http_status(:ok)
    expect(stored(message)).to include('Our reply is attached')
    expect(response.body).not_to include(NOTE)
  end

  it 'shows the note without storing it while the main body part is missing, then the text once it is back' do
    message = reply("Dear requester,\nOur reply is attached.\n", 'text/plain')
    allow_any_instance_of(FoiAttachment).
      to receive(:body_as_text).and_raise(FoiAttachment::MissingError)
    sign_in(owner)
    get page
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(NOTE)
    expect(stored(message)).to be_nil

    allow_any_instance_of(FoiAttachment).
      to receive(:body_as_text).and_call_original
    get page
    expect(response).to have_http_status(:ok)
    expect(stored(message)).to include('Our reply is attached')
  end

  it 'keeps /admin working with an unbuildable message in the holding pen' do
    message = reply(nested_html(450), 'text/html')
    message.update_columns(info_request_id: InfoRequest.holding_pen_request.id)
    sign_in(admin)
    get '/admin'
    expect(response).to have_http_status(:ok)
    expect(stored(message)).to include(NOTE)
  end

  it 'still raises other errors' do
    message = reply("Dear requester,\nOur reply is attached.\n", 'text/plain')
    allow(IncomingMessage).
      to receive(:remove_quoted_sections).
      and_raise(ArgumentError, 'wrong number of arguments')
    expect { message.get_main_body_text_folded }.to raise_error(ArgumentError)
    expect(stored(message)).to be_nil
  end
end
