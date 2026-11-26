# Delegates to a User while exposing the current HTTP request's IP address and
# user agent for UserSpamCheck scoring.
class User::WithRequest < SimpleDelegator
  attr_reader :request

  delegate :ip, :user_agent, to: :request

  def initialize(user, request)
    @request = request
    super(user)
  end
end
