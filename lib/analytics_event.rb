module AnalyticsEvent
  # modules for standardising Strings used for event categories and actions

  module Category
    OUTBOUND = "Outbound Link".freeze
    PRO_NAV_CLICK = "Pro Navigation Clicked".freeze
    VIEW_REQUEST = "View Request".freeze
    SEARCH_OFFICIAL_WEBSITE = "Search Official Website".freeze
  end

  module Action
    FACEBOOK_EXIT = 'Facebook Exit'.freeze
    MEDIUM_EXIT = 'Medium Exit'.freeze
    TWITTER_EXIT = 'Twitter Exit'.freeze
    WORDPRESS_EXIT = 'WordPress Exit'.freeze
    PRO_NAV_DASHBOARD = "Dashboard".freeze
    PRO_NAV_REQUESTS = "Requests".freeze
    PRO_NAV_MAKE_REQUEST = "Make request".freeze
    PRO_NAV_BROWSE_PUBLIC = "Browse public requests".freeze
    PRO_NAV_VIEW_AUTHORITIES = "View authorities".freeze
    PRO_NAV_HELP = "Help".freeze
    PRO_NAV_PROFILE = "Profile".freeze
    PRO_NAV_WALL = "Wall".freeze
    POSSIBLE_RELATED = "Possible related requests".freeze
  end
end
