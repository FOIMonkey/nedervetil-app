module Admin::AuthorityGroups
  # An admin's import of external releases from a CSV file.
  class ImportsController < ::AdminController
    PER_PAGE = 25

    before_action :find_import,
                  only: %i[show apply hide_releases unhide_releases]

    def index
      @imports = ::AuthorityGroups::ReleaseImport.includes(:user).
                 order(created_at: :desc, id: :desc).
                 paginate(page: params[:page].to_i.clamp(1, 10_000),
                          per_page: PER_PAGE)
      @title = 'External release imports'
    end

    def new
      @title = 'Import external releases'
    end

    def create
      import = ::AuthorityGroups::ReleaseImport.start!(file: params[:file],
                                                       user: current_user)
      redirect_to admin_external_release_import_path(import)
    rescue ::AuthorityGroups::ReleaseImport::Refused => e
      flash.now[:error] = e.message
      @title = 'Import external releases'
      render :new, status: :unprocessable_content
    end

    def show
      @title = "Import #{@import.id}"
    end

    def apply
      @import.apply!
      redirect_to admin_external_release_import_path(@import),
                  notice: 'Imported.'
    rescue ::AuthorityGroups::ReleaseImport::Refused => e
      redirect_to admin_external_release_import_path(@import),
                  flash: { error: e.message }
    end

    def hide_releases
      count = @import.releases.visible.update_all(hidden_at: Time.current,
                                                  updated_at: Time.current)
      redirect_to admin_external_release_import_path(@import),
                  notice: "#{count} hidden."
    end

    def unhide_releases
      count = @import.releases.where.not(hidden_at: nil).
              update_all(hidden_at: nil, updated_at: Time.current)
      redirect_to admin_external_release_import_path(@import),
                  notice: "#{count} shown."
    end

    private

    def find_import
      @import = ::AuthorityGroups::ReleaseImport.find(params[:id])
    end
  end
end
