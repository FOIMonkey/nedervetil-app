# Searches, lists and edits stored MailServerLog lines in the admin interface.
class Admin::MailServerLogsController < AdminController
  # A flat JSON body keeps the key it had before this controller moved here.
  wrap_parameters :admin_mail_server_log, exclude: []

  include Admin::Searchable
  include Admin::Sortable

  before_action :set_mail_server_log, only: [:edit, :update]

  sortable default: :created_at_desc, relevance: :indexed_search?,
           only: [:index]

  def index
    @title ||= 'Listing mail server logs'

    @page = page_from_params
    @query = params[:query].try(:strip)

    @mail_server_logs = measure_search(
      sorted(
        mail_server_log_scope.
          includes(:info_request).
          paginate(page: @page, per_page: 100)
      )
    )
  end

  def edit
  end

  def update
    @mail_server_log.line = params[:mail_server_log][:line]

    @mail_server_log.save!
    flash[:notice] = "Mail server log line updated"
    redirect_to edit_admin_mail_server_log_path
    # render action: 'edit'
  end

  private

  def set_mail_server_log
    @mail_server_log = MailServerLog.find(params[:id])
  end

  def mail_server_log_scope
    return base_scope if @query.blank?

    base_scope.search_scope(@query, admin_mode: true)
  end

  def base_scope
    MailServerLog
  end
end
