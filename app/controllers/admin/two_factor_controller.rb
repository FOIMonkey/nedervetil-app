# Admin-only summary of 2FA enrolment state across the user base.
class Admin::TwoFactorController < AdminController
  def show
    @all_counts = counts_for(User)
    @admin_counts = counts_for(User.with_role(:admin))
    @unenrolled_admins = User.with_role(:admin).without_two_factor.
      order(User.arel_table[:last_sign_in_at].desc.nulls_last, :id)
  end

  private

  def counts_for(scope)
    {
      total: scope.count,
      none: scope.without_two_factor.count,
      totp: scope.with_totp.count
    }
  end
end
