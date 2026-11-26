# Body bytes never appear in a cookie, mail URL or generic return record.
class PendingRequestDraft < ApplicationRecord
  include SingleUseToken
  self.token_digest_column = :browser_digest
  self.token_used_column = :claimed_at

  belongs_to :intended_user, class_name: 'User', optional: true
  belongs_to :draft_info_request, optional: true
  encrypts :payload

  def self.capture(session, title:, body:, public_body_id:)
    return unless title.is_a?(String) && body.is_a?(String)
    return if title.bytesize > 1000 || body.bytesize > 100_000

    authority = public_body_id.to_s
    return unless authority.match?(/\A[1-9]\d{0,18}\z/)

    raw, digest = new_token
    record = transaction do
      # Include expired rows: replacement must remove their encrypted body
      # without waiting for scheduled cleanup. Never delete a claimed draft.
      previous = browser_scope(session).lock.first
      previous.destroy! if previous && !previous.claimed_at
      create!(browser_digest: digest,
              payload: JSON.generate(title: title, body: body,
                                     public_body_id: authority.to_i),
              expires_at: 30.minutes.from_now)
    end
    session.delete(:pending_draft_transfer)
    session[:pending_request_draft] = { 'id' => record.id, 'secret' => raw }
    record
  end

  def self.for_browser(session)
    browser_scope(session).live.first
  end

  def self.browser_scope(session)
    state = session[:pending_request_draft]
    digest = digest_token(state['secret']) if state.is_a?(Hash)
    return none unless digest

    where(id: state['id'], browser_digest: digest)
  end
  private_class_method :browser_scope

  def bind_to(user)
    with_lock do
      return false unless live?
      return false if intended_user_id && intended_user_id != user.id

      update!(intended_user: user)
    end
  rescue ActiveRecord::RecordNotFound
    false # A simultaneous submission retired this pending body.
  end

  def transfer_token
    return unless intended_user_id && live?

    signed_id(purpose: "draft-claim:#{intended_user_id}",
              expires_at: expires_at)
  end

  def self.for_transfer(token, user)
    record = find_signed(token, purpose: "draft-claim:#{user.id}")
    record if record && record.intended_user_id == user.id && record.live?
  end

  def self.accept_transfer(session, token, user)
    return unless for_transfer(token, user)

    session[:pending_draft_transfer] = token
  end

  def self.claim(session, user)
    record = for_browser(session)
    if !record && session[:pending_draft_transfer].is_a?(String)
      record = find_signed(session[:pending_draft_transfer],
        purpose: "draft-claim:#{user.id}")
    end
    session.delete(:pending_request_draft)
    session.delete(:pending_draft_transfer)
    return unless record

    transaction do
      # A replacement can delete the row between lookup and locking.
      record = lock.find_by(id: record.id)
      return unless record

      return if !record.live? || record.intended_user_id != user.id
      return unless Ability.new(user).can?(:create, InfoRequest)

      data = JSON.parse(record.payload).slice('title', 'body', 'public_body_id')
      data['public_body_id'] =
        nil unless PublicBody.exists?(id: data['public_body_id'])
      draft = user.draft_info_requests.new(data)
      # Retain an incomplete letter for editing; sending performs validation.
      draft.save!(validate: false)
      record.update!(claimed_at: Time.current, draft_info_request: draft,
                     payload: '{}')
      draft
    end
  end
end
