# Copyright (c) 2007 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

# Searches, views, creates, edits, deletes and CSV-imports PublicBody records
# in the admin interface, closing linked change requests when processed.
class Admin::PublicBodiesController < AdminController
  # A flat JSON body keeps the key it had before this controller moved here.
  wrap_parameters :admin_public_body, exclude: []

  include Admin::Searchable
  include Admin::Sortable
  include TranslatableParams

  before_action :set_public_body, only: [:edit, :update, :destroy]

  sortable default: :updated_at_desc, only: [:show]

  def index
    lookup_query
  end

  def show
    @locale = AlaveteliLocalization.locale
    AlaveteliLocalization.with_locale(@locale) do
      @public_body = PublicBody.find(params[:id])
      @summary = AuthorityGroups::AdminSummary.new(@public_body)
      info_requests = @public_body.info_requests.order(created_at: :desc)

      @info_requests =
        sorted(info_requests).
        paginate(page: params[:page], per_page: 100)

      @versions = @public_body.versions.order(version: :desc)
      render
    end
  end

  def new
    @public_body = PublicBody.new
    @public_body.build_all_translations

    if params[:change_request_id]
      @change_request = PublicBodyChangeRequest.find(params[:change_request_id])
    end
    if @change_request
      @change_request_user_response = render_to_string(
        template: "admin/public_body_change_requests/add_accepted",
        formats: [:text]
      )
      @public_body.name = @change_request.public_body_name
      @public_body.request_email = @change_request.public_body_email
      @public_body.last_edit_comment = @change_request.comment_for_public_body
    end
    render formats: [:html]
  end

  def create
    AlaveteliLocalization.with_locale(AlaveteliLocalization.default_locale) do
      if params[:change_request_id]
        @change_request =
          PublicBodyChangeRequest.find(params[:change_request_id])
      end
      params[:public_body][:last_edit_editor] = admin_current_user
      @public_body = PublicBody.new(public_body_params)
      if @public_body.save
        if @change_request
          response_text = params[:response].gsub(
            _("[Authority URL will be inserted here]"),
            public_body_url(@public_body, only_path: false)
          )
          @change_request.close!
          @change_request.send_response(params[:subject], response_text)
        end
        flash[:notice] = 'PublicBody was successfully created.'
        redirect_to admin_body_url(@public_body)
      else
        @public_body.build_all_translations
        render action: 'new', status: :unprocessable_content
      end
    end
  end

  def edit
    @public_body.build_all_translations
    @hide_destroy_button = @public_body.info_requests.count > 0

    if params[:change_request_id]
      @change_request = PublicBodyChangeRequest.find(params[:change_request_id])
    end

    if @change_request
      @change_request_user_response =
        render_to_string(
          template: 'admin/public_body_change_requests/update_accepted',
          formats: [:text]
        )
      @public_body.request_email = @change_request.public_body_email
      @public_body.last_edit_comment = @change_request.comment_for_public_body
    else
      @public_body.last_edit_comment = ''
    end

    render formats: [:html]
  end

  def update
    if params[:change_request_id]
      @change_request = PublicBodyChangeRequest.find(params[:change_request_id])
    end
    AlaveteliLocalization.with_locale(AlaveteliLocalization.default_locale) do
      params[:public_body][:last_edit_editor] = admin_current_user
      if @public_body.update(public_body_params)
        if @change_request
          @change_request.close!
          @change_request.send_response(params[:subject], params[:response])
        end
        flash[:notice] = 'PublicBody was successfully updated.'
        redirect_to admin_body_url(@public_body)
      else
        @public_body.build_all_translations
        render action: 'edit', status: :unprocessable_content
      end
    end
  end

  def destroy
    if @public_body.info_requests.count > 0
      flash[:notice] =
        "There are requests associated with the authority, so can't destroy it"
      redirect_to admin_body_url(@public_body)
      return
    end

    @public_body.tag_string = ""
    @public_body.destroy
    flash[:notice] = "PublicBody was successfully destroyed."
    redirect_to admin_bodies_url
  end

  def import_csv
    @notes = ""
    @errors = ""
    return unless request.post?

    dry_run_only = params['commit'] != 'Upload'
    csv_contents = uploaded_csv_contents
    return if csv_contents.nil?

    # Try with dry run first
    errors, notes = PublicBody.
                      import_csv(csv_contents,
                                 params[:tag],
                                 params[:tag_behaviour],
                                 true,
                                 admin_current_user,
                                 AlaveteliLocalization.available_locales)

    if errors.empty?
      if dry_run_only
        notes.push("Dry run was successful, real run would do as above.")
        # Store the csv file for ease of performing the real run
        @temporary_csv_file = store_csv_data(csv_contents)
      else
        # And if OK, with real run
        errors, notes = PublicBody.
                          import_csv(csv_contents,
                                     params[:tag],
                                     params[:tag_behaviour],
                                     false,
                                     admin_current_user,
                                     AlaveteliLocalization.available_locales)
        raise "dry run mismatched real run" unless errors.empty?

        notes.push("Import was successful.")
      end
    end
    @errors = errors.join("\n")
    @notes = notes.join("\n")
  end

  private

  def uploaded_csv_contents
    # (FIXME: both of these cases could now be changed to use
    # PublicBody.import_csv_from_file.)
    # Read file from params
    if params[:csv_file]
      csv_contents = params[:csv_file].read
      @original_csv_file = params[:csv_file].original_filename
      csv_contents = normalize_string_to_utf8(csv_contents)
      # or from previous dry-run temporary file
    elsif params[:temporary_csv_file] && params[:original_csv_file]
      csv_contents = retrieve_csv_data(params[:temporary_csv_file])
      @original_csv_file = params[:original_csv_file]
    end
    csv_contents
  end

  # Save the contents to a temporary file - not using Tempfile as we need
  # the file to persist between requests. Return the name of the file.
  def store_csv_data(csv_contents)
    tempfile_name = "csv_upload-#{Time.zone.now.strftime("%Y%m%d")}-" \
                    "#{SecureRandom.random_number(10_000)}"
    tempfile = File.new(File.join(Dir.tmpdir, tempfile_name), 'w')
    tempfile.write(csv_contents)
    tempfile.close
    tempfile_name
  end

  # Get csv contents from the file whose name is passed, as long as the
  # name is of the expected form.
  # Delete the file, return the contents.
  def retrieve_csv_data(tempfile_name)
    unless /\Acsv_upload-\d{8}-\d{1,5}\z/.match?(tempfile_name)
      raise "Invalid filename in upload_csv: #{tempfile_name}"
    end

    tempfile_path = File.join(Dir.tmpdir, tempfile_name)
    unless File.exist?(tempfile_path)
      raise "Missing file in upload_csv: #{tempfile_name}"
    end

    csv_contents = File.read(tempfile_path)
    File.delete(tempfile_path)
    csv_contents
  end

  def lookup_query
    @locale = AlaveteliLocalization.locale
    AlaveteliLocalization.with_locale(@locale) do
      @query = params[:query]
      @query = nil if @query == ""
      @page = params[:page]
      @page = nil if @page == ""

      @public_bodies = measure_search(
        # Tags are read in a query of their own. Joined to this one they
        # would come in no order.
        public_body_scope.
          preload(:tags).
          includes(:translations).
            paginate(page: @page, per_page: 100)
      )
    end
  end

  def public_body_scope
    return locale_public_body_scope unless @query

    legacy_search? ? legacy_public_body_scope : indexed_public_body_scope
  end

  def locale_public_body_scope
    PublicBody.
      joins(:translations).
        where(public_body_translations: { locale: @locale }).
          merge(PublicBody::Translation.order(:name))
  end

  def legacy_public_body_scope
    query = <<-EOF.strip_heredoc
    (lower(public_body_translations.name)
     LIKE lower('%'||?||'%')
     OR lower(public_body_translations.short_name)
     LIKE lower('%'||?||'%')
     OR lower(public_body_translations.request_email)
     LIKE lower('%'||?||'%' ))
     AND (public_body_translations.locale = ?)
    EOF

    PublicBody.
      joins(:translations).
        where([query, @query, @query, @query, @locale]).
          merge(PublicBody::Translation.order(:name))
  end

  def indexed_public_body_scope
    PublicBody.search_scope(@query, admin_mode: true)
  end

  def public_body_params
    translatable_params(
      params[:public_body],
      translated_keys: [:locale, :name, :short_name, :request_email,
                        :publication_scheme, :disclosure_log],
      general_keys: [:tag_string, :home_page,
                     :last_edit_comment, :last_edit_editor]
    )
  end

  def set_public_body
    @public_body = PublicBody.find(params[:id])
  end
end
