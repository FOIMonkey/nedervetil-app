module Disclosures
  # Public Disclosures catalogue, feeds, reader and downloads, plus requester
  # document creation and management.
  class DocumentsController < BaseController
    include DocumentManagement

    PUBLIC = %i[index show download page_image thumbnail].freeze

    skip_before_action :html_response,
                       only: %i[index download page_image thumbnail]
    before_action :require_sign_in, except: PUBLIC
    before_action :find_document, except: %i[index create request_review yours]
    before_action :redirect_admin,
                  only: %i[manage edit update destroy withdraw]
    read_only only: %i[create request_review update destroy withdraw unwanted]
    helper_method :request_journey_page_choices

    def index
      if request.format.json? && params[:mode] == 'publications'
        return publication_feed
      end

      @search = Search.new(
        params.except(:request_choice).
          permit(:q, :page, :format, :feed, :sort, *Search::FILTERS)
      )
      if @search.filtered? || @search.page > 1 || params[:sort].present?
        set_no_crawl_headers
      end
      @title = @search.query? ? _('Search results') : _('Documents')
      if request.format.json?
        render json: @search.metadata_results.
          map { |record| public_metadata(record) }
      elsif feed_requested?
        render template: 'disclosures/documents/feed',
               formats: [:atom],
               layout: false,
               content_type: 'application/atom+xml'
      end
    end

    def show
      unless @document.stage_in?(:listed)
        return render_gone if @document.ever_published?

        raise ActiveRecord::RecordNotFound
      end
      @attribution = Attribution.new(@document)
      @boxes = @attribution.boxes
      @yours = yours_line(@document)
      @pages = @document.pages.to_a
      @document = @document.public_view
      @title = [@document.title, @document.authority&.name].compact.join(' · ')
      @reader = Reader.new(@pages, find: params[:find])
      @view = if params[:view] == 'text' ||
                 (@reader.find? && params[:view] != 'pages')
                'text'
              else
                'pages'
              end
      @view = 'pages' unless @reader.any_text?
      @more = more_from(@document)
      set_no_crawl_headers if params[:find].present? || params[:view].present?
    end

    # Includes documents kept after their request was deleted, which no request
    # page lists.
    def yours
      @title = _('Your documents')
      set_no_crawl_headers
      # Share one hash so Rails does not preload info_request twice; abilities
      # read user and FoiAttachment::SpreadsheetHold reads file_attachment.
      @documents = Document.left_joins(:info_request).
        where('info_requests.user_id = :id OR ' \
              '(disclosure_documents.request_deleted_at IS NOT NULL ' \
              'AND disclosure_documents.owner_id = :id)',
              id: current_user.id).
        includes(
          { public_body: :translations },
          info_request: [{ public_body: :translations }, :user],
          foi_attachment: [{ incoming_message: :info_request },
                           { file_attachment: :blob }]
        ).
        order(created_at: :desc, id: :desc).
        select { |document| can?(:view_document_pages, document) }
    end

    def download
      raise ActiveRecord::RecordNotFound unless @document.stage_in?(:listed)

      send_attachment_file(@document)
    end

    def page_image
      raise ActiveRecord::RecordNotFound unless @document.stage_in?(:listed)

      page = @document.pages.find_by(number: page_number)
      send_png(page&.image)
    end

    def thumbnail
      raise ActiveRecord::RecordNotFound unless @document.stage_in?(:listed)

      send_png(@document.thumbnail)
    end

    def create
      attachment = FoiAttachment.find_by(id: params[:attachment_id]) or
        raise ActiveRecord::RecordNotFound
      require_ability(:create_document, attachment)
      document = Creation.new(
        user: current_user,
        attachment: attachment,
        kind: params[:kind],
        email_text: params[:source] == 'email_text'
      ).create!
      redirect_with(disclosure_manage_document_path(document),
                    notice: _('Document made.'))
    rescue Error => e
      redirect_with(back_to_request_path(attachment), error: e.message)
    end

    def request_review
      attachment = FoiAttachment.find_by(id: params[:attachment_id]) or
        raise ActiveRecord::RecordNotFound
      require_ability(:request_document_review, attachment)
      document = Creation.new(
        user: current_user,
        attachment: attachment,
        kind: params[:kind],
        email_text: params[:source] == 'email_text'
      ).create!(for_review: true)
      redirect_with(disclosure_manage_document_path(document),
                    notice: _('Sent for admin review. Nothing is published.'))
    rescue Error => e
      redirect_with(back_to_request_path(attachment), error: e.message)
    end

    def unwanted
      require_ability(:mark_publication_unwanted)
      ReviewSubmission.unwanted!(@document, user: current_user)
      redirect_with(disclosure_manage_document_path(@document),
                    notice: _('The admin will see that you no longer want ' \
                              'it published.'))
    rescue Error => e
      redirect_with(disclosure_manage_document_path(@document),
                    error: e.message)
    end

    private

    def request_journey_page_choices
      if @search
        search_journey_choices
      elsif @document.is_a?(PublicDocument)
        { public_body: @document.authority&.url_name }
      else
        {}
      end
    end

    # Omit nil values so existing URL params are preserved.
    def search_journey_choices
      filters = @search.filters
      nation = filters[:group] if Topics::Topic::NATIONS.key?(filters[:group])
      { subject: @search.query.presence,
        public_body: filters[:body],
        journey: { 'topic' => filters[:topic], 'nation' => nation }.compact }.
        compact
    end

    def publication_feed
      if %i[q page feed sort kind topic group sector body year file_type].
           any? { |key| params[key].present? }
        return render json: { error: 'Publication feed does not accept ' \
                                     'search filters or page numbers.' },
                      status: :bad_request
      end

      feed = PublicationFeed.new(cursor: params[:cursor])
      records = feed.records
      if feed.next_cursor
        url = disclosure_documents_url(format: :json,
                                       mode: 'publications',
                                       cursor: feed.next_cursor)
        response.headers['link'] = "<#{url}>; rel=\"next\""
      end
      render json: records.map { |record| public_metadata(record) }
    rescue PublicationFeed::InvalidCursor
      render json: { error: 'Invalid or expired publication cursor.' },
             status: :bad_request
    rescue PublicationFeed::ScanLimit
      render json: { error: 'Publication feed temporarily unavailable.' },
             status: :service_unavailable
    end

    def feed_requested?
      params[:feed] == '1' || request.format.atom? || request.format.xml?
    end

    def public_metadata(record)
      { id: record.public_id,
        title: record.title,
        description: record.description,
        kind: record.kind,
        authority: record.public_body&.name,
        document_date: record.document_date,
        released_on: record.released_on,
        published_at: record.first_published_at,
        url: disclosure_document_url(record) }
    end

    def more_from(document)
      authority = document.authority or return
      search = Search.new(body: authority.url_name)
      others = search.results.
        reject { |other| other.id == document.id }.first(2)
      { authority: authority, search: search, documents: others } if others.any?
    end

    # Links go to the document's pages, not its request: the public page never
    # links a private request.
    def yours_line(document)
      return unless can?(:view_document_pages, document)

      { mine: current_user&.id == document.requester_id,
        redact: publish_flow_redact_path(document),
        withdraw: can?(:withdraw_document, document),
        manage: disclosure_manage_document_path(document) }
    end

    def render_gone
      @title = _('Document withdrawn')
      render :gone, status: :gone
    end
  end
end
