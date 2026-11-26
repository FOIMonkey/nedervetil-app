# Base controller for admin Disclosures pages; includes document-access
# helpers and requires a signed-in user for ability checks.
class Admin::Disclosures::BaseController < AdminController
  include ::Disclosures::DocumentAccess

  # Document permissions require a user even with external admin authentication.
  def authenticate
    return require_sign_in unless authenticated?

    super
  end
end
