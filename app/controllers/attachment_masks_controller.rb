##
# Controller to process FoiAttachment objects before being served publicly by
# applying masks and censor rules.
#
class AttachmentMasksController < ApplicationController
  before_action :set_no_crawl_headers
  before_action :decode_referer, :ensure_referer
  before_action :find_attachment, :ensure_attachment

  def wait
    if @attachment.masked?
      redirect_to done_attachment_mask_path(
        id: @attachment.to_signed_global_id,
        referer: verifier.generate(@referer)
      )

    else
      @attachment.mask_later
    end
  end

  def done
    return if @attachment.masked?

    redirect_to wait_for_attachment_mask_path(
      id: @attachment.to_signed_global_id,
      referer: verifier.generate(@referer)
    )
  end

  private

  def decode_referer
    @referer = verifier.verified(params[:referer])
  end

  def find_attachment
    @attachment = GlobalID::Locator.locate_signed(params[:id])
  rescue ActiveRecord::RecordNotFound
    @attachment = nil
  end

  def ensure_referer
    raise RouteNotFound unless @referer
  end

  def ensure_attachment
    redirect_to(@referer) unless @attachment
  end

  def verifier
    Rails.application.message_verifier('AttachmentsController')
  end
end
