module Admin::AuthorityFeeds
  # Sections are added in code, as each needs a reader.
  class FeedsController < ::AdminController
    before_action :find_feed

    def edit
      @title = "Edit #{@feed.heading}"
    end

    def update
      if @feed.update(feed_params)
        redirect_to admin_authority_pages_path,
                    notice: "#{@feed.heading} saved."
      else
        @title = "Edit #{@feed.heading}"
        render :edit, status: :unprocessable_content
      end
    end

    private

    def find_feed
      @feed = ::AuthorityFeeds::Feed.find(params[:id])
    end

    def feed_params
      permitted = params.require(:feed).
                  permit(:heading, :tab, :position, :updates, :only_tags,
                         :source_line, :licence, :hidden, spotlights: [])
      hidden = permitted.delete(:hidden)
      permitted[:spotlights] = Array(permitted[:spotlights]).compact_blank
      unless hidden.nil?
        permitted[:hidden_at] =
          hidden == '1' ? (@feed.hidden_at || Time.current) : nil
      end
      permitted
    end
  end
end
