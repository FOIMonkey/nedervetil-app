# Copyright (c) 2008 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

# Serves the public home page of topics and latest disclosures (redirecting
# signed-in accounts to the inbox), the JSON version endpoint and fallback 404.
class GeneralController < ApplicationController
  skip_before_action :html_response, only: :version

  before_action :redirect_accounts_to_inbox, only: :frontpage

  def frontpage
    @topics = Topics::Topic.home
    @topic_count = Topics::Topic.all.size
    latest = Disclosures::Search.new({})
    @latest = latest.results.first(Topics::TopicsController::LATEST)
    @latest_sheets = latest.sheet_previews
    @title = site_name
    render template: 'topics/topics/home'
  end

  # Handle requests for non-existent URLs - will be handled by ApplicationController::render_exception
  def not_found
    raise RouteNotFound
  end

  # Exposes public document count only; never leak private request/user counts.
  def version
    respond_to do |format|
      format.json do
        render json: {
          alaveteli_git_commit: Statistics::General.new.alaveteli_git_commit,
          alaveteli_version: ALAVETELI_VERSION,
          ruby_version: RUBY_VERSION,
          public_document_count: Disclosures::Document.listed.count
        }
      end
    end
  end

  private

  def redirect_accounts_to_inbox
    redirect_to alaveteli_pro_dashboard_path if current_user
  end
end
