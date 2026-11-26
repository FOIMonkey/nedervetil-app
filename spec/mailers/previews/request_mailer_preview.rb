class RequestMailerPreview < ActionMailer::Preview
  def new_response_public
    RequestMailer.new_response(info_request, incoming_message)
  end

  private

  def info_request
    InfoRequest.new(
      title: 'A request',
      url_title: 'a_request',
      user: User.first,
      public_body: PublicBody.first,
      described_state: 'successful'
    )
  end

  def incoming_message
    IncomingMessage.new(
      id: 123,
      info_request: info_request,
      raw_email: RawEmail.new,
      last_parsed: Time.now,
      sent_at: Time.now
    )
  end
end
