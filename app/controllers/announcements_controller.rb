# Dismisses an Announcement for the current user via AnnouncementDismissal or
# in the visitor's session, supporting both XHR and standard form submissions.
class AnnouncementsController < ApplicationController
  def destroy
    if announcement
      store_dismissal_in_session unless dismissal.save
      # The announcement-dismiss controller asks in the background.
      if request.xhr?
        head :ok
      else
        redirect_back fallback_location: frontpage_path
      end
    else
      head :forbidden
    end
  end

  private

  def dismissal
    @dismissal ||= AnnouncementDismissal.find_or_initialize_by(
      announcement: announcement,
      user: current_user
    )
  end

  def announcement
    return @announcement if defined?(@announcement)

    @announcement = Announcement.find_by(id: params.require(:id))
  end

  def store_dismissal_in_session
    session[:announcement_dismissals] ||= []
    session[:announcement_dismissals] << announcement.id
  end
end
