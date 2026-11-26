# Shows the theme's help pack (lib/help_site.rb) through the help_site views.
# With no pack, /help lists the older help pages.
class HelpSiteController < ApplicationController
  skip_before_action :html_response, only: :search
  before_action { HelpSite.reload_in_development! }

  def show
    return render :fallback unless HelpSite.pack?

    path = ['/help', params[:section], params[:answer]].compact.join('/')
    @page = HelpSite.content.page(path)
    raise ActiveRecord::RecordNotFound unless @page

    @title = @page.title
    render @page.view, locals: { section: @page.section, answer: @page.answer }
  end

  def search
    render json: HelpSite.content.search_index
  end
end
