module AuthenticationHelpers
  def sign_in(user)
    @request.env['devise.mapping'] = Devise.mappings[:user]
    if user
      # Controller specs arrange a completed session. Request specs exercise
      # password/OTP verification and the restricted enrolment flow.
      if user.is_admin? && !user.totp?
        user.update!(otp_secret: User.generate_otp_secret,
                     otp_required_for_login: true)
      end
      Authentication::Session.establish(@request, user, two_factor: user.totp?)
    else
      @request.env['warden'].logout(:user)
    end
  end
end

RSpec.configure do |config|
  config.include Devise::Test::ControllerHelpers, type: :controller
  config.include AuthenticationHelpers, type: :controller
end
