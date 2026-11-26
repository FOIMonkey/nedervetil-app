module Admin::AuthorityFeeds
  # Unticked items are kept as holds_not:<key> tags, so they also show (and can
  # be bulk edited) with the authority's other tags.
  class HoldsController < ::AdminController
    def update
      body = PublicBody.find(params[:id])
      keys = ::AuthorityFeeds::Holdings.new(body).all.
        filter_map { |holder, _| holder.key }.uniq
      ticked = Array(params[:held]) & keys
      ::AuthorityFeeds::Holdings.untick!(body, keys - ticked,
                                       editor: admin_current_user)
      redirect_to admin_body_path(body, anchor: 'body-holds'),
                  notice: 'What they hold saved.'
    end
  end
end
