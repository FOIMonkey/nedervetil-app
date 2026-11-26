# One-use bounded navigation, with no submitted credentials or form values.
class AuthenticationReturn < ApplicationRecord
  include SingleUseToken

  belongs_to :user, optional: true

  def self.remember(session, path, user: nil)
    destination = Authentication::ReturnPath.normalize(path)
    previous = session[:authentication_return]
    unless destination == Authentication::ReturnPath::DEFAULT
      raw, digest = new_token
    end
    transaction do
      previous_digest = digest_token(previous)
      where(token_digest: previous_digest).delete_all if previous_digest
      if raw
        create!(token_digest: digest, path: destination,
                user: user, expires_at: 15.minutes.from_now)
      end
    end
    session.delete(:authentication_return)
    session[:authentication_return] = raw if raw
  end

  def self.consume(session, user)
    raw = session.delete(:authentication_return)
    transaction do
      record = lock.find_by_token(raw)
      return Authentication::ReturnPath::DEFAULT unless record
      if !record.live? || (record.user_id && record.user_id != user.id)
        return Authentication::ReturnPath::DEFAULT
      end

      record.use!
      Authentication::ReturnPath.normalize(record.path)
    end
  end
end
