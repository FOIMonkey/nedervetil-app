module Disclosures
  # The requester deletes a request and its emails and keeps its documents
  # (RequestDeletion).
  class RequestDeletionsController < BaseController
    before_action :require_sign_in
    before_action :find_request
    read_only only: :create

    def new
      @title = _('Delete the emails, keep the documents')
      set_no_crawl_headers
      @documents = @deletion.documents.
        includes(foi_attachment: :incoming_message).
        select { |document| @deletion.readable?(document) }
      @blockers = @deletion.blockers
    end

    def create
      unless params[:confirm] == '1'
        return redirect_with(
          request_deletion_path(url_title: @info_request.url_title),
          error: _('Tick that you want to delete the request and its emails.')
        )
      end

      @deletion.delete!
      redirect_with(disclosure_your_documents_path,
                    notice: _('The request and its emails were deleted.'))
    rescue Error => e
      redirect_with(request_deletion_path(url_title: @info_request.url_title),
                    error: e.message)
    end

    private

    def find_request
      @info_request = find_info_request!(:read, url_title: params[:url_title])
      @deletion = RequestDeletion.new(@info_request, current_user)
      raise ActiveRecord::RecordNotFound unless @deletion.offered?
    end
  end
end
