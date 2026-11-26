module AlaveteliFeatures
  # Mixed into views, controllers, mailers and models to check whether a
  # Flipper feature is enabled and to enable or disable features per actor.
  module Helpers
    def feature_enabled?(feature, *args)
      AlaveteliFeatures.backend.enabled?(feature, *args)
    end

    def enable_actor(feature, user)
      # check feature hasn't already been enabled for the user
      return true if feature_enabled?(feature, user)

      AlaveteliFeatures.backend.enable_actor(feature, user)
    end

    def disable_actor(feature, user)
      # check feature isn't already been disabled for the user
      return true unless feature_enabled?(feature, user)

      AlaveteliFeatures.backend.disable_actor(feature, user)
    end
  end
end
