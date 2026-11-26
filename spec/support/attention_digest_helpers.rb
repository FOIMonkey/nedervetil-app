require_relative 'lean_attention_helpers'

# Daily summaries read committed rows, so these examples run without a
# transaction and remove what they made afterwards.
RSpec.shared_context 'with attention digest rows' do
  self.use_transactional_tests = false
  include_context 'with lean attention predictions'
  let(:user) { FactoryBot.create(:user, trusted: true) }

  before do
    @initial_user_ids = User.pluck(:id)
    @initial_body_ids = PublicBody.pluck(:id)
    ActionMailer::Base.deliveries.clear
  end

  after do
    created_ids = User.where.not(id: @initial_user_ids).pluck(:id)
    request_ids = InfoRequest.where(user_id: created_ids).pluck(:id)
    IncomingAttention::Prediction.where(info_request_id: request_ids).delete_all
    InfoRequest.where(id: request_ids).find_each(&:destroy!)
    InfoRequestBatch.where(user_id: created_ids).find_each(&:destroy!)
    User.where(id: created_ids).find_each(&:destroy!)
    PublicBody.where.not(id: @initial_body_ids).find_each(&:destroy!)
  end

  def response(route = nil, verified: true, owner: user, frequency: :daily, due: 1.minute.ago, target: nil)
    target ||= FactoryBot.create(:info_request, user: owner,
                                                use_notifications: false)
    synthetic = Mail.new do
      from 'synthetic-responder@example.invalid'
      to target.incoming_email
      subject 'Synthetic response'
      message_id "lean-digest-#{SecureRandom.uuid}@example.invalid"
      content_type 'text/plain; charset=UTF-8'
      body 'Wholly synthetic correspondence.'
      date Time.current
    end
    message = target.send(
      :create_response!,
      synthetic,
      message_id: synthetic.message_id,
      message_checksum: Digest::SHA1.hexdigest(synthetic.encoded)
    )
    lean_prediction(message, route, verified: verified) if route
    notice = FactoryBot.create(:notification,
                               user: owner,
                               info_request_event: message.response_event,
                               frequency: frequency,
                               send_after: due)
    [target, message, notice,
     IncomingAttention::Prediction.for_message(message)]
  end

  def send_daily
    NotificationMailer.send_daily_notifications
  end

  def body
    ActionMailer::Base.deliveries.last.body.decoded
  end
end
