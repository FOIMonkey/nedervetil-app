# Renders detail panes for the Option C split triage desk (Today queue) and
# searchable list previews. Works inside a <turbo-frame> and as a standalone
# full-page destination when JavaScript is disabled.
class Admin::TriageController < AdminController
  def show
    response.headers['Cache-Control'] = 'private, no-store'
    response.headers['Vary'] = 'Turbo-Frame'

    @kind = params[:kind].to_s
    @frame_id = @kind == 'request_preview' ? 'request_preview' : 'triage_detail'
    @standalone = !turbo_frame_request?

    load_triage_record!
    @title = triage_page_title

    render :show, layout: (@standalone ? 'admin' : false)
  end

  private

  def load_triage_record!
    case @kind
    when 'holding_pen' then load_holding_pen!
    when 'request', 'request_preview' then load_request!
    when 'change_request' then load_change_request!
    when 'document' then load_document!
    when 'attachment' then load_attachment!
    when 'blank_contact' then @public_body = PublicBody.find(params[:id])
    else raise ActiveRecord::RecordNotFound
    end
  end

  def load_holding_pen!
    @incoming_message = IncomingMessage.includes(:raw_email, :info_request).
                        find(params[:id])
    unless can?(:admin, @incoming_message.info_request) &&
           @incoming_message.info_request.holding_pen_request?
      raise ActiveRecord::RecordNotFound
    end

    @raw_email = @incoming_message.raw_email
    @holding_pen_context = Admin::HoldingPenContext.new(@raw_email)
    @holding_pen = @holding_pen_context.in_holding_pen?
    return unless @holding_pen

    @public_bodies = @holding_pen_context.public_bodies
    @guessed_info_requests = @holding_pen_context.guessed_info_requests
    @rejected_reason = @holding_pen_context.rejected_reason
  end

  def load_request!
    @info_request = InfoRequest.includes(:user, public_body: :translations).
                    find(params[:id])
    raise ActiveRecord::RecordNotFound unless can?(:admin, @info_request)

    @outgoing_count = @info_request.outgoing_messages.count
  end

  def load_change_request!
    @change_request = PublicBodyChangeRequest.includes(:public_body, :user).
                      find(params[:id])
  end

  def load_document!
    @document = Disclosures::Document.
                includes(:foi_attachment, public_body: :translations).
                find(params[:id])
    raise ActiveRecord::RecordNotFound unless can?(:manage_document, @document)
  end

  def load_attachment!
    @revision = AttachmentManagement::Revision.
                includes(:user, foi_attachment: :incoming_message).
                find(params[:id])
    return if can?(:replace_attachment, @revision.foi_attachment)

    raise ActiveRecord::RecordNotFound
  end

  def triage_page_title
    case @kind
    when 'holding_pen' then "Holding pen message ##{@incoming_message.id}"
    when 'request', 'request_preview' then "Request ##{@info_request.id}"
    when 'change_request' then "Change request ##{@change_request.id}"
    when 'document' then @document.title
    when 'attachment' then @revision.foi_attachment.display_filename
    when 'blank_contact' then @public_body.name
    else 'Triage'
    end
  end
end
