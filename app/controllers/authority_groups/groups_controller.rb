module AuthorityGroups
  # Public authority group pages; never cached so withdrawn documents leave
  # them immediately.
  class GroupsController < Disclosures::BaseController
    INDEX_SIZE = 12
    BROWSE_SIZE = 60
    SECTION_SIZES = { 'documents' => 25,
                      'releases' => 50,
                      'authorities' => 100,
                      'foi_record' => 20 }.freeze
    # Groups up to 1,000 (~100 KB) list members by kind; larger ones paginate.
    KINDS_MAX = 1_000
    # Cap pagination depth to avoid expensive deep-offset scans.
    MAX_PAGE = 200

    before_action :find_group, only: %i[show section]
    helper_method :admin?

    def index
      @headings = Group.headings
      @title = _('Authorities')
      return browse if params[:by].present?

      @listings = @headings.transform_values do |heading|
        Group.listing(heading).paginate(page: 1, per_page: INDEX_SIZE)
      end
      redirect_to list_public_bodies_default_path if
        @listings.values.all?(&:empty?)
    end

    def show
      @title = @group.title
    end

    def section
      @section = params[:section]
      @title = "#{@group.title}: #{section_title}"
      if @section == 'authorities' && @group.body_ids.size <= KINDS_MAX
        return @kinds = @group.bodies_by_kind
      end

      @items = case @section
               when 'documents' then @group.public_documents
               when 'releases' then @group.latest_releases
               when 'authorities' then @group.bodies_by_name
               else @page.decisions
               end.paginate(page: page_param,
                            per_page: SECTION_SIZES.fetch(@section))
    end

    private

    def browse
      @key = params[:by].to_s
      heading = @headings[@key] or raise ActiveRecord::RecordNotFound
      @groups = Group.listing(heading).paginate(page: page_param,
                                                per_page: BROWSE_SIZE)
      @title = Group.label(@key)
      render :browse
    end

    def find_group
      @group = Group.find(params[:tag].to_s, include_hidden: admin?) or
        raise ActiveRecord::RecordNotFound
      @page = Page.new(@group)
    end

    def admin?
      can?(:admin, Group)
    end

    def page_param
      page = [params[:page].to_i, 1].max
      page > MAX_PAGE ? raise(ActiveRecord::RecordNotFound) : page
    end

    def section_title
      { 'documents' => _('released here'),
        'releases' => _('released on their own sites'),
        'authorities' => _('authorities'),
        'foi_record' => _('FOI record') }.fetch(@section)
    end
  end
end
