# Copyright (c) 2008 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

# Renders the signed-in user's inbox dashboard along with undismissed inbox
# announcements.
class AlaveteliPro::DashboardController < AlaveteliPro::BaseController
  def index
    @user = current_user
    @announcements = Announcement.
      for_user(current_user, Announcement::INBOX).
      preload(:translations).
      limit(3)
  end
end
