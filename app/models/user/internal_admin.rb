# The "internal admin" is a special user for internal use.
module User::InternalAdmin
  extend ActiveSupport::Concern

  class_methods do
    def internal_admin_user
      user = find_by(email: AlaveteliConfiguration.contact_email)
      return user if user

      password = SecureRandom.hex(32)

      user = new(
        name: 'Internal admin user',
        email: AlaveteliConfiguration.contact_email,
        password: password,
        password_confirmation: password
      )
      user.skip_confirmation_notification!
      user.save!
      user
    end
  end

  # Whether this is the internal admin, without the lookup above, which
  # creates the account when it's missing.
  def internal_admin_user?
    email == AlaveteliConfiguration.contact_email
  end
end
