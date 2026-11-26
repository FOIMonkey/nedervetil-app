module Disclosures
  # Requester-facing flow to choose, redact, check and publish documents from
  # a single reply; only chosen files and approved details go public.
  class PublishingController < BaseController
    # Box editor holds unsaved state on the page and relies on full-load
    # beforeunload prompts (doc/FORK.md).
    turbo_drive false, only: :redact

    skip_before_action :html_response, only: :status
    before_action :require_sign_in
    before_action :find_reply
    read_only only: %i[save_choice publish ask_admin try_again hide_name
                       apply_redaction start_again]
    helper_method :publish_file_name, :publish_file_ready?, :publish_sheet?,
                  :can_hide?, :done?, :stuck?, :own_title?

    NOTE_LIMIT = 500

    def choose
      @reply = choices.reply
      @title = choices.title
    end

    def save_choice
      choices.apply!(chosen_files)
      first = chosen_documents.
        find { |document| can?(:publish_own_document, document) }
      unless first
        return redirect_with(request_page,
                             notice: _('Nothing from this reply is public.'))
      end

      redirect_to publish_reply_check_path(**reply_args)
    rescue Error => e
      refused(publish_reply_path(**reply_args), e)
    end

    def redact
      @documents = chosen_documents
      @document = chosen_document
      @attachment = @document.foi_attachment
      @can_redact = @attachment.present? && can?(:redact_document, @document)
      prepare_redact_editor if @can_redact
      @title = _('Hide something')
      AttachmentManagement::CleanupJob.enqueue_if_due
    end

    def apply_redaction
      document = chosen_document
      require_ability(:redact_document, document)
      result = RequesterRedaction.new(
        document, user: current_user, ability: current_ability
      ).apply!(**redaction_params)
      if result.continue_from
        return redirect_to publish_reply_redact_path(
          **reply_args, id: document, from: result.continue_from.id
        )
      end

      redirect_with(publish_reply_check_path(**reply_args),
                    notice: result.notice)
    rescue AttachmentManagement::NewRevision::Invalid,
           AttachmentManagement::Boxes::Invalid,
           AttachmentManagement::TextRedaction::Rejected,
           AttachmentManagement::Replacement::Refused,
           Error => e
      refused(publish_reply_redact_path(**reply_args, id: document), e)
    end

    def ask_admin
      document = chosen_document
      require_ability(:manage_document, document)
      note = params[:note].to_s.strip.first(NOTE_LIMIT)
      if note.empty?
        return redirect_with(publish_reply_redact_path(**reply_args,
                                                       id: document),
                             error: _('Tell us what needs to be hidden.'))
      end

      document.log!('review_requested', user: current_user)
      document.log!('hide_requested', user: current_user, note: note)
      redirect_with(publish_reply_check_path(**reply_args),
                    notice: _('An admin will hide it before it goes public.'))
    rescue Error => e
      refused(publish_reply_check_path(**reply_args), e)
    end

    def hide_name
      document = chosen_document
      require_ability(:redact_document, document)
      require_ability(:publish_own_document, document)
      attachment = document.foi_attachment
      raise Error::Refused, _('This file is no longer there.') unless attachment

      notice = NameMask.hide_for_requester!(attachment, user: current_user,
                                                        document: document)
      redirect_to publish_reply_published_path(**reply_args), notice: notice
    rescue Error => e
      refused(publish_reply_check_path(**reply_args), e)
    end

    def start_again
      document = chosen_document
      require_ability(:withdraw_document, document)
      outcome = document.take_down_and_start_again!(by: current_user)
      notice = if outcome == :restored
                 _('Taken down and restored from the original email.')
               else
                 _('Taken down. Original emails are deleted after 120 days, ' \
                   'so earlier redactions can’t be undone. You can still ' \
                   'add further redactions or share it as it is.')
               end
      redirect_with(publish_reply_check_path(**reply_args), notice: notice)
    rescue Error => e
      refused(publish_reply_check_path(**reply_args), e)
    end

    def try_again
      reply_documents.start_stuck_again!(current_user)
      redirect_to publish_reply_check_path(**reply_args)
    rescue Error => e
      refused(publish_reply_check_path(**reply_args), e)
    end

    def read
      @document = chosen_document
      raise ActiveRecord::RecordNotFound unless @document.servable?

      @pages = @document.pages.to_a
      @attachment = @document.foi_attachment
      prepare_draft_read if @pages.empty? && @attachment
      @title = publish_file_name(@document)
    end

    def check
      @documents = chosen_documents
      step = PublishCheck.new(reply_documents)
      @to_publish = step.to_publish
      return render_waiting(step) if step.preparing.any?

      @problems = step.problems
      @pending = step.pending
      @review = step.review
      @ready = step.ready
      @attributions = step.attributions
      @name_hits = step.name_hits
      @hide_name = step.hide_name
      @consents = {}
      @title = step.title
    end

    def publish
      ids = Array(params[:documents]).map(&:to_s).uniq
      documents = chosen_documents.
        select { |document| ids.include?(document.public_id) }
      if documents.empty? || documents.size != ids.size
        raise ActiveRecord::RecordNotFound
      end

      RequesterPublication.publish_all!(documents, user: current_user)
      redirect_to publish_reply_published_path(**reply_args)
    rescue Error => e
      refused(publish_reply_check_path(**reply_args), e)
    end

    def published
      reply = PublishedReply.new(reply_documents)
      @documents = reply.listed
      @waiting = reply.waiting
      @withdrawn = reply.withdrawn
      @title = reply.title
    end

    def status
      render json: reply_documents.status(with_reply: params[:what] == 'reply')
    end

    private

    def reply_documents
      @reply_documents ||= ReplyDocuments.new(@info_request, @message,
                                              current_ability)
    end

    def choices
      @choices ||= ReplyChoices.new(reply_documents, user: current_user)
    end

    def chosen_documents
      reply_documents.all
    end

    def chosen_document
      reply_documents.find!(params[:id])
    end

    def chosen_files
      if params[:all].present?
        choices.likely
      elsif params[:files].is_a?(ActionController::Parameters)
        params[:files]
      else
        {}
      end
    end

    def publish_file_ready?(document)
      reply_documents.ready?(document)
    end

    def publish_file_name(document)
      return _('Their email') if document.source_kind == 'email_text'

      document.foi_attachment&.display_filename.presence || document.title
    end

    def publish_sheet?(document)
      document.filename.to_s.match?(/\.(xlsx|xlsm|xls|csv)\z/i)
    end

    def can_hide?(document)
      reply_documents.can_hide?(document)
    end

    def own_title?(document)
      Titles.own_title?(document)
    end

    def stuck?(document)
      reply_documents.stuck?(document)
    end

    def done?(row)
      choices.done?(row)
    end

    def refused(path, error)
      redirect_with(path,
                    error: { partial: 'disclosures/publishing/refused',
                             locals: { message: error.message } })
    end

    def render_waiting(step)
      @stuck = step.stuck
      @title = step.waiting_title
      render :waiting
    end

    def find_reply
      @info_request = find_info_request!(:read, url_title: params[:url_title])
      @message =
        @info_request.incoming_messages.find_by(id: params[:message_id]) or
        raise ActiveRecord::RecordNotFound
      @message.association(:info_request).target = @info_request
      require_ability(:publish_from_reply, @message)
      set_no_crawl_headers
    end

    def reply_args
      { url_title: @info_request.url_title, message_id: @message.id }
    end

    def request_page
      show_request_path(url_title: @info_request.url_title)
    end

    def redaction_params
      { kind: params[:kind].to_s,
        boxes: params[:boxes],
        text: params[:text],
        parent_id: params[:parent_id],
        reason: params[:reason] }
    end

    def prepare_redact_editor
      bytes = @attachment.body
      capabilities = AttachmentManagement::Capabilities.new(@attachment)
      if @document.source_kind == 'email_text' || @attachment.main_body_part?
        @text = convert_string_to_utf8(bytes.dup, 'UTF-8').string.
          gsub("\r\n", "\n")
      elsif capabilities.kind == :pdf
        @page_count = preview_page_count(@attachment, bytes, 'pdf')
      elsif capabilities.requester_word_to_pdf?
        @conversion = ready_word_conversion(@attachment, bytes)
        if @conversion
          @page_count = @conversion.previews.page_count
        else
          @can_convert_word = true
        end
      end
    rescue AttachmentManagement::Unsupported
      @conversion = nil
      @page_count = 0
    end

    def ready_word_conversion(attachment, bytes)
      scope = AttachmentManagement::Revision.where(
        foi_attachment_id: attachment.id,
        user_id: current_user.id,
        kind: 'office_pdf',
        status: 'ready',
        source_sha256: Digest::SHA256.hexdigest(bytes)
      )
      if params[:from].present?
        scope.find_by(id: params[:from])
      else
        scope.order(id: :desc).first
      end
    end

    def prepare_draft_read
      bytes = @attachment.body
      format = Formats.for(@attachment.content_type, @attachment.filename,
                           bytes)
      if %w[text csv].include?(format) || @document.source_kind == 'email_text'
        @text = convert_string_to_utf8(bytes.dup, 'UTF-8').string.
          gsub("\r\n", "\n")
      elsif can?(:manage_attachment, @attachment)
        @page_count = preview_page_count(@attachment, bytes, format)
      end
    end

    def preview_page_count(attachment, bytes, format)
      unless format == 'pdf' ||
             AttachmentManagement.engine(job: nil).
               coder_for(attachment.content_type)
        return 0
      end

      AttachmentManagement::Previews.new(
        attachment_id: attachment.id,
        sha256: Digest::SHA256.hexdigest(bytes),
        content_type: attachment.content_type
      ) { bytes }.page_count
    rescue AttachmentManagement::Unsupported
      0
    end
  end
end
