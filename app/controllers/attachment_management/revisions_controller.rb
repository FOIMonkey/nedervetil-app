module AttachmentManagement
  # Drafts that replace an attachment: making one, checking it, and applying
  # or discarding it.
  class RevisionsController < BaseController
    include BoxEditor

    skip_before_action :html_response, only: [:file, :page]
    before_action :publish_instead, except: :page
    before_action :find_revision, except: :create
    helper_method :confirmable?

    def create
      revision, input = new_revision.build(
        params[:kind],
        boxes: params[:boxes],
        parent_id: params[:parent_id],
        text: params[:text],
        upload: params[:file],
        black_mask: params[:black_mask] == '1'
      )
      revision.save!
      attach_input(revision, input)
      ProcessJob.perform_later(revision.id)
      redirect_to manage_attachment_revision_path(@attachment, revision)
    rescue TextRedaction::Rejected => e
      hand_back_rejected_text(e.message)
    rescue NewRevision::Invalid, Boxes::Invalid => e
      flash[:error] = e.message
      redirect_back(fallback_location: manage_attachment_path(@attachment))
    end

    def show
      @capabilities = capabilities
      @page_count =
        if @revision.ready? && @revision.output_kind.in?(%i[pdf image])
          @revision.previews.page_count
        else
          0
        end
      if @revision.ready? && @revision.output_kind == :text
        @text = @revision.output_bytes.force_encoding('UTF-8').scrub
      end
      @unmaskable_with_black_rules = unmaskable_with_black_rules?
      @title = _('Check the draft')
    end

    def file
      unless @revision.ready? || @revision.applied?
        raise ActiveRecord::RecordNotFound
      end
      raise ActiveRecord::RecordNotFound unless @revision.output.attached?

      send_file_bytes(@revision.output_bytes,
                      filename: @revision.output_filename,
                      content_type: @revision.output_content_type,
                      inline: params[:inline].present?)
    end

    def page
      unless @revision.ready? && @revision.output.attached?
        raise ActiveRecord::RecordNotFound
      end

      send_png(@revision.previews.png(page_param))
    rescue ArgumentError, Unsupported
      raise ActiveRecord::RecordNotFound
    end

    def apply
      unless confirmable?(@revision)
        raise Replacement::Refused,
              _('Only an admin can confirm this draft: ' \
                'it does more than redact.')
      end
      unless params[:reviewed] == '1'
        raise Replacement::Refused,
              _('Tick the box to say you have checked the new file.')
      end
      if @revision.format_change? && params[:accept_format_change] != '1'
        raise Replacement::Refused,
              _('Tick the box to accept the change of format.')
      end

      replacement = Replacement.new(
        @revision,
        editor: current_user,
        reason: params[:reason],
        confirmed_sha256: params[:output_sha256].to_s
      )
      replacement.apply!
      set_apply_flash!(replacement)
      redirect_to foi_attachment_path(@attachment.reload)
    rescue Replacement::Stale => e
      flash[:error] = e.message
      redirect_to manage_attachment_path(@attachment)
    rescue Replacement::Refused => e
      flash[:error] = e.message
      redirect_to manage_attachment_revision_path(@attachment, @revision)
    end

    def discard
      if @revision.processing? || @revision.ready? || @revision.failed?
        @revision.discard!
      end
      redirect_to manage_attachment_path(@attachment),
                  notice: _('Draft discarded.')
    end

    private

    def set_apply_flash!(replacement)
      if replacement.black_mask_status == :failed
        flash[:error] = black_mask_failed_message(replacement)
      elsif replacement.demoted_from_public?
        flash[:notice] = demoted_from_public_message(replacement)
      elsif replacement.black_mask_status == :unmaskable
        flash[:notice] = _(
          'The attachment has been replaced. Automatic black masking ' \
          'doesn’t run on this file format, so check that any protected ' \
          'information is already removed or hide the attachment in admin.'
        )
      else
        flash[:notice] = _('The attachment has been replaced. ' \
                           'Its links now give the new file.')
      end
    end

    def black_mask_failed_message(replacement)
      if replacement.demoted_from_public?
        _('The attachment has been replaced and taken off the public site, ' \
          'but automatic black masking failed on the new file. The requester ' \
          'can see it as uploaded and it can’t be published. Hide it or ' \
          'upload a redacted or unencrypted copy if it contains protected ' \
          'information.')
      else
        _('The attachment has been replaced, but automatic black masking ' \
          'failed on the new file. The requester can see it as uploaded ' \
          'and it can’t be published. Hide it or upload a redacted or ' \
          'unencrypted copy if it contains protected information.')
      end
    end

    def demoted_from_public_message(replacement)
      if replacement.black_mask_status == :unmaskable
        _('The attachment has been replaced and taken off the public site ' \
          'because a check or privacy rule flagged it. Automatic black ' \
          'masking doesn’t run on this file format, so check it carefully ' \
          'or hide it if it contains protected information.')
      else
        _('The attachment has been replaced and taken off the public site ' \
          'because a check or privacy rule flagged it.')
      end
    end

    def unmaskable_with_black_rules?
      return false if redact_only? || !@revision.ready?
      return false unless @info_request&.masks_for(:requester)&.
        censor_rules&.any?
      return true if @revision.kind == 'pdf_redaction'

      format = Disclosures::Formats.declared(
        @revision.output_content_type.presence || @attachment.content_type,
        @revision.output_filename.presence || @attachment.filename
      )
      !Disclosures::RuleRemask::MASKABLE.include?(format)
    end

    def confirmable?(revision)
      revision.confirmable_by?(current_ability)
    end

    # A draft is seen only by whoever made it and by admins: an unconfirmed
    # draft can hold text the attachment doesn't (an upload, a free edit).
    def find_revision
      @revision = Revision.find_by!(id: params[:id],
                                    foi_attachment_id: @attachment.id)
      raise ActiveRecord::RecordNotFound unless
        can?(:view_attachment_draft, @revision)
    end

    def new_revision
      @new_revision ||= NewRevision.new(@attachment,
                                        user: current_user,
                                        ability: current_ability,
                                        capabilities: capabilities)
    end

    def hand_back_rejected_text(message)
      flash.now[:error] = message
      @editable = true
      @text = params[:text].to_s.gsub("\r\n", "\n")
      @title = _('Edit the text')
      render 'attachment_management/attachments/edit_text',
             status: :unprocessable_content
    end

    # Stash raw text/upload on output until ProcessJob validates it.
    def attach_input(revision, input)
      return unless input

      revision.output.attach(io: StringIO.new(input.b),
                             filename: 'input',
                             content_type: 'application/octet-stream',
                             identify: false)
    end
  end
end
