# Re-reads a reply's sealed RawEmail while it is kept.
class Admin::IncomingMessages::ReadingsController < AdminController
  before_action :set_incoming_message, :check_info_request

  def create
    unless @incoming_message.raw_email&.kept?
      return redirect_to edit_admin_incoming_message_path(@incoming_message),
                         error: 'This reply’s email is no longer kept, so ' \
                                'it can’t be read again.'
    end

    @incoming_message.read_again!
    redirect_to edit_admin_incoming_message_path(@incoming_message),
                notice: 'The email has been read again.'
  rescue MailHandler::ReadRefused
    redirect_to edit_admin_incoming_message_path(@incoming_message),
                error: 'The email can’t be read just now. Try again in a ' \
                       'few minutes.'
  rescue RawEmail::Erasable::ErasedError
    redirect_to edit_admin_incoming_message_path(@incoming_message),
                error: 'This reply’s email is no longer kept, so it can’t ' \
                       'be read again.'
  rescue IncomingMessage::Attachments::UnableToExtractAttachments
    redirect_to edit_admin_incoming_message_path(@incoming_message),
                error: 'The email now reads without a protected part, so it ' \
                       'was left as it was.'
  end

  private

  def set_incoming_message
    @incoming_message = IncomingMessage.find(params[:incoming_message_id])
  end

  def check_info_request
    return if can? :admin, @incoming_message.info_request

    raise ActiveRecord::RecordNotFound
  end
end
