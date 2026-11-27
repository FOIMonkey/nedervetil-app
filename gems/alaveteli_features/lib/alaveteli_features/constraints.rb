module AlaveteliFeatures
  module Constraints
    # Route constraint that matches only when a named feature flag is enabled.
    class FeatureConstraint
      include AlaveteliFeatures::Helpers

      def initialize(feature)
        @feature = feature
      end

      def matches?(_request)
        feature_enabled? @feature
      end
    end
  end
end
