# A new reply is held back from Pro lists and notifications until its
# importance check completes.
module ReplyCheckHelpers
  def complete_reply_checks(info_request)
    info_request.incoming_messages.each do |message|
      IncomingAttention::Prediction.for_message(message)&.
        update!(status: 'complete')
    end
  end
end

RSpec.configure do |config|
  config.include ReplyCheckHelpers
end
