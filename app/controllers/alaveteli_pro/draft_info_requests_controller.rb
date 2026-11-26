# Copyright (c) 2008 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

# Deletes a signed-in user's unsent DraftInfoRequest from the inbox drafts list.
class AlaveteliPro::DraftInfoRequestsController < AlaveteliPro::BaseController
  read_only :requests, only: %i[destroy]

  # Idempotent and non-disclosing: missing or foreign IDs redirect identically.
  def destroy
    current_user.draft_info_requests.destroy_by(id: params[:id])
    redirect_to alaveteli_pro_info_requests_path(
      'alaveteli_pro_request_filter[filter]' => 'draft'
    ), notice: _('Draft deleted.')
  end
end
