module Admin::AuthorityGroups
  # Titles, intros, order and tags are edited in the category admin;
  # membership comes from authority tags.
  class GroupsController < ::AdminController
    PER_PAGE = 100

    def index
      @headings = ::AuthorityGroups::Group.headings
      @key = if @headings.key?(params[:heading])
               params[:heading]
             else
               @headings.keys.first
             end
      @groups = @key &&
                ::AuthorityGroups::Group.admin_listing(@headings[@key]).
                  paginate(page: params[:page].to_i.clamp(1, 10_000),
                           per_page: PER_PAGE)
      @map_check = ::AuthorityGroups::Map.check
      @title = 'Authority groups'
    end

    def hide
      ::AuthorityGroups::Setting.hide!(category)
      redirect_back_or_to admin_authority_groups_path,
                          notice: "“#{category.title}” is hidden from visitors."
    end

    def unhide
      ::AuthorityGroups::Setting.show!(category)
      redirect_back_or_to admin_authority_groups_path,
                          notice: "“#{category.title}” is shown."
    end

    private

    def category
      headings = ::AuthorityGroups::Group.headings.values.map(&:id)
      @category ||= Category.joins(:parent_relationships).
                    find_by!(id: params[:category_id],
                             category_relationships: { parent_id: headings })
    end
  end
end
