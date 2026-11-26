module Disclosures
  # Shared manage, edit, update, destroy and withdraw actions mixed into public
  # and admin Disclosures document controllers.
  module DocumentManagement
    EDITABLE = %w[title description document_date kind].freeze

    def manage
      unless can?(:view_document_pages, @document)
        raise ActiveRecord::RecordNotFound
      end

      @pages = @document.pages.to_a
      @manager = manager?
      @title = @document.title
      set_no_crawl_headers
    end

    def edit
      require_ability(:edit_document)
      @title = _('Edit details: {{title}}', title: @document.title)
    end

    def update
      require_ability(:edit_document)
      saved = locked(:edit_document) do
        unless @document.update(flow_details.merge(updated_by: current_user))
          next false
        end

        changes = @document.saved_changes.slice(*EDITABLE).
          transform_values { |(_, to)| to.to_s.truncate(200) }
        if changes.any?
          TopicMatch.record(@document) if @document.published?
          @document.log!('details_changed',
                         user: current_user,
                         changes: changes)
        end
        true
      end
      if saved
        back = publish_flow_check_path(@document) if params[:flow] == 'check'
        return redirect_with(back || disclosure_manage_document_path(@document),
                             notice: _('Details saved.'))
      end

      @title = _('Edit details: {{title}}', title: @document.title_was)
      render :edit, status: :unprocessable_content
    end

    def destroy
      require_ability(:delete_document)
      unless params[:confirm] == '1'
        return redirect_with(
          disclosure_manage_document_path(@document),
          error: _('Tick that you want to delete the draft.')
        )
      end

      request_page = back_to_request_path(@info_request)
      locked(:delete_document) do
        @document.purge_public_pages!
        @document.destroy!
      end
      destination = if @document.request_deleted?
                      disclosure_your_documents_path
                    else
                      request_page
                    end
      redirect_with(destination, notice: _('The draft document was deleted.'))
    end

    def withdraw
      require_ability(:withdraw_document)
      locked(:withdraw_document) do
        Publication.new(@document, user: current_user).
          withdraw!(reason: params[:reason])
      end
      redirect_with(
        flow_receipt_path || disclosure_manage_document_path(@document),
        notice: _('Withdrawn. It is no longer public.')
      )
    rescue Error => e
      redirect_with(
        flow_receipt_path || disclosure_manage_document_path(@document),
        error: e.message
      )
    end

    private

    def details_params
      params.require(:document).
        permit(:title, :description, :document_date, :kind)
    end

    # In the check flow, a blank title keeps the suggested title for the kind.
    def flow_details
      details = details_params
      return details unless params[:flow] == 'check' &&
                            details[:title].blank? &&
                            !Titles.own_title?(@document)

      kind = details[:kind].presence || @document.kind
      details.merge(title: Titles.suggest(kind,
                                          @document.info_request,
                                          @document.released_on))
    end

    def locked(action)
      @document.with_lock do
        require_ability(action)
        yield
      end
    end

    def flow_receipt_path
      message = @document.incoming_message
      return unless params[:flow] == '1' && message &&
                    message.info_request_id == @document.info_request_id &&
                    can?(:publish_from_reply, message)

      publish_reply_published_path(url_title: message.info_request.url_title,
                                   message_id: message.id)
    end

    def back_to_request_path(record)
      info_request = record.is_a?(InfoRequest) ? record : record&.info_request
      if info_request
        show_request_path(url_title: info_request.url_title)
      else
        disclosure_documents_path
      end
    end
  end
end
