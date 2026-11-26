# Redirects when READ_ONLY is set or the feature is in READ_ONLY_FEATURES.
#
#   read_only :followups, only: [:create]
#   read_only only: [:create] # global mode only
module ReadOnly
  extend ActiveSupport::Concern

  # Views ask this too, for example whether sign-ups are closed.
  def self.feature?(feature)
    AlaveteliConfiguration.read_only.present? ||
      (feature.present? &&
       AlaveteliConfiguration.read_only_features.map(&:to_sym).
         include?(feature.to_sym))
  end

  # Controller declarations for read-only checks.
  module ClassMethods
    def read_only(*feature, **options)
      prepend_before_action(options) do |controller|
        controller.send(:check_read_only_feature, feature[0])
      end
    end
  end

  private

  def check_read_only_feature(feature)
    return false unless read_only_feature?(feature)

    flash[:notice] = _("{{site_name}} is currently in maintenance. {{message}}",
                       site_name: site_name, message: read_only_message)

    redirect_to frontpage_url
  end

  def read_only_message
    AlaveteliConfiguration.read_only
  end

  def read_only_feature?(feature)
    ReadOnly.feature?(feature)
  end
end
