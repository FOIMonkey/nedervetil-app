module Deadlines
  # Changes to a request's deadlines are only for those who may make them;
  # anyone else, or anyone signed out, gets the 404 a stranger would.
  class BaseController < ::ApplicationController
    before_action :require_sign_in
    before_action :find_request

    private

    def find_request
      @info_request = find_info_request!(:adjust_deadlines,
                                         id: params[:request_id])
    end
  end
end
