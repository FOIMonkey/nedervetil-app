module Disclosures
  # Base controller for non-admin Disclosures routes. Mixes in DocumentAccess
  # and redirects administrators to the corresponding /admin/disclosures action.
  class BaseController < ::ApplicationController
    include DocumentAccess

    private

    def redirect_admin
      return unless can?(:admin, @document)

      query = request.query_parameters.slice('compare', 'prepared', 'v', 'flow')
      destination = query.merge(
        controller: "/admin/disclosures/#{controller_name}",
        action: action_name, id: @document,
        number: params[:number], page: params[:page], only_path: true
      )
      redirect_to url_for(destination), status: :temporary_redirect
    end
  end
end
