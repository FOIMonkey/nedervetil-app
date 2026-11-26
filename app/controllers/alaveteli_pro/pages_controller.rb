# Copyright (c) 2017 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

# Renders static templates under app/views/alaveteli_pro/pages without
# requiring sign-in.
class AlaveteliPro::PagesController < AlaveteliPro::BaseController
  skip_before_action :require_inbox_sign_in

  def show
    unless template_exists? "alaveteli_pro/pages/#{params[:id]}"
      raise ActiveRecord::RecordNotFound
    end

    render template: "alaveteli_pro/pages/#{params[:id]}"
  end
end
