module Authentication
  # Shared by controllers and Rack routes. Only fetch an existing Warden
  # session here: never run a password strategy from an arbitrary request.
  class Session
    KEY = 'complete_authentication'.freeze
    TTL = 3.hours

    def self.user(request)
      warden = request.env['warden']
      return unless warden

      user = warden.user(scope: :user)
      return unless user

      proof = warden.session(:user)[KEY]
      valid = proof_valid?(proof, user)
      unless valid
        warden.logout(:user)
        return
      end
      proof['at'] = Time.current.to_i
      user
    end

    private_class_method def self.proof_valid?(proof, user)
      valid = proof.is_a?(Hash) &&
              proof['version'] == user.authentication_version &&
              proof['at'].is_a?(Integer) && proof['at'] <= Time.current.to_i &&
              proof['at'] > TTL.ago.to_i && user.active_for_authentication?
      valid &&= proof['two_factor'] && user.totp? if user.otp_required_for_login
      valid
    end

    def self.admin?(request)
      user = self.user(request)
      user && user.totp? && AlaveteliConfiguration.enable_two_factor_auth &&
        Ability.new(user).can?(:access, :admin)
    end

    # Call only after the Warden two-factor strategies succeed, or after the
    # restricted enrolment proves its password-bound challenge and new TOTP.
    def self.establish(request, user, two_factor:)
      raise ArgumentError,
        'incomplete authentication' unless user.active_for_authentication?
      raise ArgumentError,
        'account requires two factors' if user.otp_required_for_login &&
                                          (!two_factor || !user.totp?)

      warden = request.env.fetch('warden')
      warden.logout(:user)
      warden.set_user(user, scope: :user)
      warden.session(:user)[KEY] = {
        'version' => user.authentication_version,
        'at' => Time.current.to_i,
        'two_factor' => two_factor
      }
      user.record_sign_in(ip: request.remote_ip, user_agent: request.user_agent)
    end
  end
end
