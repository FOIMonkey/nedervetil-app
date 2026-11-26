# Formats a HealthChecks result message for the health checks status page,
# styling failed checks in red.
module HealthChecksHelper
  def check_status(check)
    style = check.ok? ? '' : 'color: red'
    content_tag(:b, check.message, style: style)
  end
end
