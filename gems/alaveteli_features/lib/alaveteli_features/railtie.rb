require 'alaveteli_features/helpers'

module AlaveteliFeatures
  # Rails integration that mixes AlaveteliFeatures::Helpers into ActionView and
  # ActionController and registers the install generator.
  class Railtie < Rails::Railtie
    initializer "alaveteli_features.helpers" do
      ActiveSupport.on_load :action_view do
        include AlaveteliFeatures::Helpers
      end
      ActiveSupport.on_load :action_controller do
        include AlaveteliFeatures::Helpers
      end
    end
    generators do
      # rubocop:disable Layout/LineLength -- a require path
      require 'alaveteli_features/generators/alaveteli_features/install/install_generator'
      # rubocop:enable Layout/LineLength
    end
  end
end
