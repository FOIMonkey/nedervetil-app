module Admin::AuthorityGroups
  # Admin pages for external releases: listing, editing, hiding and pinning.
  class ReleasesController < ::AdminController
    PER_PAGE = 50
    STATES = %w[shown hidden pinned].freeze

    before_action :find_release, except: %i[index new create]

    def index
      @releases = filtered.includes(public_body: :translations).newest_first.
                  paginate(page: params[:page].to_i.clamp(1, 10_000),
                           per_page: PER_PAGE)
      @title = 'External releases'
    end

    def new
      @release = ::AuthorityGroups::ExternalRelease.
                 new(released_on: Date.current)
      @body_name = params[:body]
    end

    def create
      @release = ::AuthorityGroups::ExternalRelease.
                 new(release_params.merge(edited_at: Time.current))
      unless assign_body && @release.save
        return render :new, status: :unprocessable_content
      end

      redirect_to admin_external_releases_path(body: @body_name),
                  notice: 'Release added.'
    end

    def edit
      @body_name = @release.public_body.url_name
    end

    def update
      @release.assign_attributes(release_params.merge(edited_at: Time.current))
      unless assign_body && @release.save
        return render :edit, status: :unprocessable_content
      end

      redirect_to admin_external_releases_path(body: @body_name),
                  notice: 'Release saved. ' \
                          'Imports won’t change its title or date.'
    end

    def destroy
      @release.destroy!
      redirect_to admin_external_releases_path,
                  notice: 'Release deleted. A later import of the same link ' \
                          'adds it again; hide it to keep it off.'
    end

    def hide
      curate(hidden_at: Time.current)
    end

    def unhide
      curate(hidden_at: nil)
    end

    def pin
      curate(pinned_at: Time.current)
    end

    def unpin
      curate(pinned_at: nil)
    end

    private

    def filtered
      scope = ::AuthorityGroups::ExternalRelease.all
      if params[:q].present?
        scope = scope.where(
          'external_releases.title ILIKE ?',
          "%#{::AuthorityGroups::ExternalRelease.sanitize_sql_like(params[:q])}%"
        )
      end
      if params[:body].present?
        scope = scope.where(
          public_body_id: PublicBody::Translation.
            where(url_name: params[:body]).select(:public_body_id)
        )
      end
      if params[:import].present?
        scope = scope.where(external_release_import_id: params[:import])
      end
      case params[:state]
      when 'shown' then scope.visible
      when 'hidden' then scope.where.not(hidden_at: nil)
      when 'pinned' then scope.pinned
      else scope
      end
    end

    def find_release
      @release = ::AuthorityGroups::ExternalRelease.find(params[:id])
    end

    def release_params
      params.require(:external_release).
        permit(:title, :url, :released_on, :log_url)
    end

    # Returns the authority named, or nil after adding an error.
    def assign_body
      @body_name = params[:body].to_s.strip
      body = if @body_name.present?
               PublicBody.find_by_url_name_with_historic(@body_name)
             end
      if body
        @release.public_body = body
      else
        @release.errors.add(:base, 'No authority has that URL name.')
      end
      body
    end

    def curate(changes)
      @release.update_columns(changes.merge(updated_at: Time.current))
      redirect_back_or_to admin_external_releases_path
    end
  end
end
