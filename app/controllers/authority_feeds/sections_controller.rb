module AuthorityFeeds
  # The Overview tab is /body/<name> (PrivateArchive renders it).
  class SectionsController < ::ApplicationController
    PER_PAGE = 20
    SIDE_RELEASES = 10
    MAX_PAGE = 1_000

    before_action :find_body

    def documents
      @search = Disclosures::Search.new(body: @public_body.url_name,
                                        q: params[:q],
                                        page: params[:page])
      @page = Page.new(@public_body, documents: documents?)
      return overview unless @page.tab?('documents')

      @query = params[:q].to_s.strip.first(200)
      releases = @page.releases
      if @query.present?
        releases = releases.where(
          'title ILIKE ?',
          "%#{ActiveRecord::Base.sanitize_sql_like(@query)}%"
        )
      end
      # Releases page separately; beside documents they are a shorter list.
      @releases =
        releases.order(Arel.sql('pinned_at IS NULL'),
                       released_on: :desc, id: :desc).
        paginate(page: page_number(:releases_page),
                 per_page: @search.results.any? ? SIDE_RELEASES : PER_PAGE)
      tab 'documents', _('Documents')
    end

    def foi_record
      @page = Page.new(@public_body, documents: documents?)
      return overview unless @page.tab?('foi_record')

      statistics = @page.feed(FoiStatistics::FEED)
      @years = if statistics && @page.foi_record
                 FoiStatistics.years_for(statistics, @public_body)
               else
                 []
               end
      @decisions = @page.decisions.paginate(page: page_number,
                                            per_page: PER_PAGE)
      tab 'foi_record', _('FOI record')
    end

    private

    def find_body
      @public_body =
        PublicBody.find_by_url_name_with_historic(params[:url_name]) or
        raise ActiveRecord::RecordNotFound
    end

    def documents?
      Disclosures::Document.listed.exists?(public_body_id: @public_body.id)
    end

    def page_number(key = :page)
      params[key].to_i.clamp(1, MAX_PAGE)
    end

    def overview
      redirect_to(public_body_path(@public_body))
    end

    def tab(key, label)
      @tab = key
      @title = "#{@public_body.name}: #{label}"
      render template: "authority_feeds/sections/#{key}"
    end
  end
end
