# An account that looks new: not the internal admin account or an admin, not
# confirmed_not_spam, and with no requests or classifications. An admin's
# profile is never limited, whatever their account's state.
module User::LimitedProfile
  extend ActiveSupport::Concern

  def limited_profile?
    self != User.internal_admin_user &&
      !is_admin? &&
      !confirmed_not_spam? &&
      info_requests_count.zero? &&
      status_update_count.zero?
  end
end
