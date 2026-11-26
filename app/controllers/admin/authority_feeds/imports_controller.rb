module Admin::AuthorityFeeds
  # An admin's upload of a feed's file: a preview, then applying it.
  class ImportsController < ::AdminController
    PROBLEMS_SHOWN = 200

    before_action :find_feed
    before_action :find_import, only: %i[show apply]

    def new
      @title = "Upload #{@feed.heading.downcase}"
    end

    def create
      import = ::AuthorityFeeds::Import.start!(feed: @feed,
                                               file: params[:file],
                                               user: current_user)
      redirect_to admin_authority_feed_import_path(@feed, import)
    rescue ::AuthorityFeeds::Import::Refused => e
      flash.now[:error] = e.message
      @title = "Upload #{@feed.heading.downcase}"
      render :new, status: :unprocessable_content
    end

    def show
      @title = "Upload #{@import.id}"
    end

    def apply
      @import.apply!
      redirect_to admin_authority_feed_import_path(@feed, @import),
                  notice: 'Uploaded.'
    rescue ::AuthorityFeeds::Import::Refused => e
      redirect_to admin_authority_feed_import_path(@feed, @import),
                  flash: { error: e.message }
    end

    private

    def find_feed
      @feed = ::AuthorityFeeds::Feed.find(params[:authority_feed_id])
    end

    def find_import
      @import = @feed.imports.find(params[:id])
    end
  end
end
