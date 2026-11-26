# Signs in via the form. Sends Origin because ApplicationController checks it
# on signed-out requests when forgery protection is enabled.
module RequestSignInHelpers
  def sign_in(user)
    if user.is_admin? && !user.totp?
      user.update!(otp_secret: User.generate_otp_secret,
                   otp_required_for_login: true)
    end
    code = nil
    if user.totp?
      # Arrange a fresh fixture proof; replay is tested by dedicated flows.
      user.update_columns(consumed_timestep: nil)
      code = user.current_otp
    end
    post '/profile/sign_in',
         params: { user_signin: { email: user.email,
                                  password: 'jonespassword',
                                  otp_attempt: code } },
         headers: { 'Origin' => "http://#{host}" }
  end

  def sign_in!(user)
    sign_in(user)
    expect_signed_in_as(user)
  end

  def expect_signed_in_as(user)
    expect(session['warden.user.user.key']&.first).to eq([user.id])
  end
end

RSpec.configure do |config|
  config.include RequestSignInHelpers, type: :request
end
