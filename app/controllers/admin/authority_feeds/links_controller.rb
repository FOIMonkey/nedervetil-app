module Admin::AuthorityFeeds
  # Admin pages for the links on authority pages.
  class LinksController < ::AdminController
    before_action :find_link, only: %i[edit update destroy]

    def new
      position = (::AuthorityFeeds::Link.maximum(:position) || 0) + 10
      @link = ::AuthorityFeeds::Link.new(position: position)
      @title = 'Add link'
    end

    def create
      @link = ::AuthorityFeeds::Link.new(link_params)
      if @link.save
        return redirect_to(admin_authority_pages_path,
                           notice: "#{@link.label} added.")
      end

      @title = 'Add link'
      render :new, status: :unprocessable_content
    end

    def edit
      @title = "Edit #{@link.label}"
    end

    def update
      if @link.update(link_params)
        return redirect_to(admin_authority_pages_path,
                           notice: "#{@link.label} saved.")
      end

      @title = "Edit #{@link.label}"
      render :edit, status: :unprocessable_content
    end

    def destroy
      @link.destroy!
      redirect_to admin_authority_pages_path, notice: "#{@link.label} deleted."
    end

    private

    def find_link
      @link = ::AuthorityFeeds::Link.find(params[:id])
    end

    def link_params
      params.require(:link).permit(:label, :url_template, :tag, :position)
    end
  end
end
