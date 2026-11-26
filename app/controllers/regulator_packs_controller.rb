# Serves temporary regulator-pack ZIP archives to authenticated, authorised
# readers via a signed download token.
class RegulatorPacksController < ApplicationController
  def show
    return require_sign_in_for_pack unless authenticated?

    payload = RegulatorPack.verify_token(params[:token])
    unless payload && payload[:user_id] == @user.id
      return render_gone(_('This download link has expired or is not valid.'))
    end

    @info_request = InfoRequest.find_by(id: payload[:info_request_id])
    unless @info_request && can?(:read, @info_request)
      raise ActiveRecord::RecordNotFound
    end

    path = RegulatorPack.ready_path(payload[:pack_id],
                                    info_request_id: payload[:info_request_id])
    return render_gone(_('This download link has expired.')) unless path

    send_file(path,
              filename: "#{@info_request.url_title}.zip",
              type: 'application/zip')
  end

  private

  def require_sign_in_for_pack
    ask_to_login(
      web: _('To download your request pack'),
      email: _('Then you can download your request zip file.'),
      email_subject: _('Log in to download your request zip file')
    )
  end

  def render_gone(message)
    render plain: message, status: :gone
  end
end
