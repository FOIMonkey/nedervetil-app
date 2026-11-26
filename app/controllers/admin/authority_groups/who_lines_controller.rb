module Admin::AuthorityGroups
  # Saves an admin's Who does what line for one authority.
  class WhoLinesController < ::AdminController
    def update
      body = PublicBody.find(params[:id])
      if ::AuthorityGroups::WhoLine.save_for(body, params[:line])
        redirect_to admin_body_path(body, anchor: 'body-who'),
                    notice: 'Who does what saved.'
      else
        redirect_to admin_body_path(body, anchor: 'body-who'),
                    flash: { error: 'That’s too long. ' \
                                    "Keep it to #{::AuthorityGroups::WhoLine::MAX} characters." }
      end
    end
  end
end
