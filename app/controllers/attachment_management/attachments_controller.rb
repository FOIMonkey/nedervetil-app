module AttachmentManagement
  # The management page for one attachment, its box and text editors, and
  # the files and page images they load.
  class AttachmentsController < BaseController
    include BoxEditor

    skip_before_action :html_response, only: [:current, :page]
    before_action :publish_instead, only: [:show, :redact, :edit_text]

    def show
      @capabilities = capabilities
      @available = attachment_available?
      @page_count, @unsupported = page_count_or_reason
      @office_findings = office_findings
      @drafts = Revision.where(foi_attachment: @attachment).newest_first.
        includes(:user).limit(50).
        select { |draft| can?(:view_attachment_draft, draft) }.first(20)
      @title = _('Manage attachment')
      CleanupJob.enqueue_if_due
    end

    def current
      raise ActiveRecord::RecordNotFound unless attachment_available?

      send_file_bytes(attachment_bytes, filename: @attachment.display_filename,
                                        content_type: @attachment.content_type,
                                        inline: params[:inline].present?)
    end

    def page
      raise ActiveRecord::RecordNotFound unless attachment_available?

      send_png(attachment_previews.png(page_param))
    rescue ArgumentError, Unsupported
      raise ActiveRecord::RecordNotFound
    end

    def redact
      if params[:from]
        parent = Revision.find_by!(id: params[:from],
                                   foi_attachment_id: @attachment.id,
                                   kind: 'office_pdf',
                                   status: 'ready')
        unless can?(:view_attachment_draft, parent) &&
               can?(:replace_attachment, @attachment)
          raise ActiveRecord::RecordNotFound
        end

        prepare_box_editor(
          parent: parent,
          boxes: Boxes.from_instructions(
            'boxes' => parent.instructions['carried_boxes'] || {}
          )
        )
      else
        unless capabilities.redact_boxes? && attachment_available? &&
               (!redact_only? || capabilities.kind == :pdf)
          raise ActiveRecord::RecordNotFound
        end

        prepare_box_editor
      end
    rescue Unsupported => e
      flash[:error] = e.explanation
      redirect_to manage_attachment_path(@attachment)
    end

    def edit_text
      unless capabilities.edit_text? && attachment_available? &&
             can?(:edit_attachment_text, @attachment) &&
             (!redact_only? || capabilities.main_body?)
        raise ActiveRecord::RecordNotFound
      end

      @text = attachment_text
      @editable = true
      @title = _('Edit text')
    end

    private

    def page_count_or_reason
      return [0, nil] unless capabilities.redact_boxes? && attachment_available?

      [attachment_previews.page_count, nil]
    rescue Unsupported => e
      [0, e]
    end

    def office_findings
      return [] unless capabilities.kind == :office && attachment_available?

      Tempfile.create('office-inspect') do |file|
        file.binmode
        file.write(attachment_bytes)
        file.flush
        OfficeInspector.findings(file.path)
      end
    end
  end
end
