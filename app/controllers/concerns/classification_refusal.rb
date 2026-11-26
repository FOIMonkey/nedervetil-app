# Handles CanCan::AccessDenied for classification: returns 403 for the
# requester (e.g. suspended) and prompts anyone else to sign in as them.
module ClassificationRefusal
  extend ActiveSupport::Concern

  included do
    rescue_from CanCan::AccessDenied do |error|
      if authenticated?(as: info_request.user)
        render_permission_denied(error)
      else
        ask_to_login(
          as: info_request.user,
          web: _('To classify the response to this FOI request'),
          email: _('Then you can classify the FOI response you have got ' \
                   'from {{authority_name}}.',
                   authority_name: info_request.public_body.name),
          email_subject: _('Classify an FOI response from {{authority_name}}',
                           authority_name: info_request.public_body.name)
        )
      end
    end
  end
end
