# Provides the no-op track_analytics_event view helper referenced by navigation
# and footer links.
module AnalyticsHelper
  # Use categories and actions from lib/analytics_event.rb.

  def track_analytics_event(event_category, event_action, options = {})
    # noop, not implemented for GA4 yet
  end
end
