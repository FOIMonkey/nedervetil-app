# Displays the Disclosures review queue of documents waiting for administrator
# checks.
class Admin::Disclosures::ReviewsController < Admin::Disclosures::BaseController
  def index
    unless can?(:review_documents, ::Disclosures::Document)
      raise ActiveRecord::RecordNotFound
    end

    set_no_crawl_headers
    @title = _('Review queue')
    @queue = ::Disclosures::ReviewQueue.new(current_ability)
  end
end
