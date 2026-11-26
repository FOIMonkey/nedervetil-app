# Per-controller/action Turbo Drive opt-out (`turbo_drive false, only: ...`).
# Document each opt-out in doc/FORK.md and public/helpers/full_load_links.js.
# Reload meta applies only to GET/HEAD so failed POSTs keep entered text;
# earlier filters (e.g. sign-in) keep Drive enabled.
module TurboDrive
  extend ActiveSupport::Concern

  included do
    helper_method :turbo_drive?, :turbo_visit_reload?, :load_in_full!,
                  :keep_no_turbo_copy!, :keep_no_turbo_copy?
  end

  class_methods do
    def turbo_drive(enabled, **options)
      before_action(**options) { @turbo_drive = enabled }
    end
  end

  private

  def turbo_drive?
    @turbo_drive != false
  end

  def turbo_visit_reload?
    !turbo_drive? && (request.get? || request.head?)
  end

  # Allows views (e.g. turnstile_box) to opt out before the layout renders.
  def load_in_full!
    @turbo_drive = false
  end

  # Prevent caching private signed-out pages, such as password reset links.
  def keep_no_turbo_copy!
    @keep_no_turbo_copy = true
  end

  def keep_no_turbo_copy?
    @keep_no_turbo_copy == true
  end
end
