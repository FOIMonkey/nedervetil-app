# Administrative management of Disclosures::Document records.
class Admin::Disclosures::DocumentsController < Admin::Disclosures::BaseController
  include ::Disclosures::DocumentManagement

  skip_before_action :html_response, only: %i[download page_image]
  before_action :find_document
  before_action { require_ability(:admin) }
  read_only except: %i[manage edit download page_image]

  def manage
    super
    prepare_draft_preview if @pages.empty? && @document.servable?
  end

  def download
    raise ActiveRecord::RecordNotFound unless @document.servable?

    send_attachment_file(@document)
  end

  def page_image
    page = @document.pages.find_by(number: page_number)
    return send_png(page.image) if page&.image&.attached?
    raise ActiveRecord::RecordNotFound unless @document.servable?

    attachment = @document.foi_attachment
    path = draft_previews(attachment, attachment.body.to_s).png(page_number)
    send_png_content(path: path.to_s)
  rescue ArgumentError, AttachmentManagement::Unsupported
    raise ActiveRecord::RecordNotFound
  end

  def publish
    require_ability(:publish_document)
    ::Disclosures::Publication.new(@document, user: current_user).publish!
    redirect_with(disclosure_manage_document_path(@document),
                  notice: 'Published for the requester. It is now public.')
  rescue ::Disclosures::Error => e
    redirect_with(disclosure_manage_document_path(@document), error: e.message)
  end

  def erase
    require_ability(:erase_document)
    unless params[:confirm] == '1'
      return redirect_with(
        disclosure_manage_document_path(@document),
        error: 'Tick that you want to erase every file of this document.'
      )
    end

    ::Disclosures::Publication.new(@document, user: current_user).erase!
    redirect_with(disclosure_manage_document_path(@document),
                  notice: 'Erased. Only a record of the document is left.')
  end

  private

  def prepare_draft_preview
    attachment = @document.foi_attachment
    bytes = attachment.body.to_s
    format = ::Disclosures::Formats.for(attachment.content_type,
                                        attachment.filename,
                                        bytes)
    if %w[text csv].include?(format) || @document.source_kind == 'email_text'
      @draft_text = convert_string_to_utf8(bytes.dup, 'UTF-8').string.
        gsub("\r\n", "\n")
    else
      @draft_page_count = draft_page_count(attachment, bytes, format)
    end
  end

  def draft_page_count(attachment, bytes, format)
    return 0 unless draft_previewable?(attachment, format)

    draft_previews(attachment, bytes).page_count
  rescue AttachmentManagement::Unsupported
    0
  end

  def draft_previewable?(attachment, format)
    format == 'pdf' ||
      AttachmentManagement.engine(job: nil).
        coder_for(attachment.content_type).present?
  end

  def draft_previews(attachment, bytes)
    AttachmentManagement::Previews.new(
      attachment_id: attachment.id,
      sha256: Digest::SHA256.hexdigest(bytes),
      content_type: attachment.content_type
    ) { bytes }
  end
end
