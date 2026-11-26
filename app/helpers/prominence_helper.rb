##
# Methods to render consistently object's prominence and prominence_reason
# depending on the context (prominence value, current user, format)
#
module ProminenceHelper
  def concealed_prominence?(prominenceable)
    if prominenceable.is_a?(FoiAttachment)
      return prominenceable.prominence == 'hidden'
    end

    %w[hidden requester_only].include?(prominenceable&.prominence)
  end

  def render_prominence(prominenceable, format: :html)
    return unless concealed_prominence?(prominenceable)

    klass = prominenceable.class::Prominence::Helper
    prominence = klass.new(self, prominenceable)

    return prominence.notice + ("\n" * 2) if format == :text

    # rubocop:disable Rails/OutputSafety -- each part is made by _(), which escapes the reason an admin typed; squish would lose the parts' safe mark
    [prominence.notice, prominence.sign_in, prominence.contact_us].
      join(' ').squish.html_safe
    # rubocop:enable Rails/OutputSafety
  end

  # Intentionally omits which file or why so check findings are not disclosed.
  def hidden_file_notice
    _('We’ve hidden this file. Please {{contact_us_link}} if you have any ' \
      'questions.',
      contact_us_link: link_to(_('contact us'), help_contact_path))
  end

  def hidden_reply_text_notice
    _('We’ve hidden the text of this reply. Please {{contact_us_link}} if ' \
      'you have any questions.',
      contact_us_link: link_to(_('contact us'), help_contact_path))
  end

  class Base # :nodoc:
    attr_reader :prominenceable

    delegate :current_user, :request, :link_to, :can?,
             :help_contact_path, :signin_path, to: :@helper

    def self.default_prominence_reason
      _('Requests on this site are private until they are published.')
    end

    def initialize(helper, prominenceable)
      @helper = helper
      @prominenceable = prominenceable
    end

    def info_request
      raise NotImplementedError
    end

    def user
      info_request.user
    end

    def admin?
      can?(:admin, info_request)
    end

    def notice
      @notice ||= (
        case prominenceable.prominence
        when 'hidden'
          hidden_notice
        when 'requester_only'
          requester_only_notice
        else
          raise NotImplementedError
        end
      )
    end

    def contact_us
      return if admin?

      contact_us_notice(
        contact_us_link: link_to(_('contact us'), help_contact_path)
      )
    end

    def sign_in
      return if prominenceable.prominence != 'requester_only'
      return if current_user && current_user == user
      return if admin?

      sign_in_notice(
        sign_in_link: link_to(_('sign in'), signin_path(r: request.fullpath))
      )
    end

    private

    def hidden_notice
      raise NotImplementedError
    end

    def requester_only_notice
      raise NotImplementedError
    end

    def contact_us_notice(*args)
      _('Please {{contact_us_link}} if you have any questions.', *args)
    end

    def sign_in_notice(*args)
      raise NotImplementedError
    end

    def reason
      prominenceable.prominence_reason.presence || default_prominence_reason
    end

    def default_prominence_reason
      return '' if admin?

      self.class.default_prominence_reason
    end
  end

  class InfoRequest::Prominence::Helper < Base # :nodoc:
    def info_request
      prominenceable
    end

    def hidden_notice
      if admin?
        _('This request has prominence "hidden". {{reason}} You can only see ' \
          'it because you are logged in as a super user.', reason: reason)
      else
        _('This request has not been published. {{reason}}', reason: reason)
      end
    end

    def requester_only_notice
      if current_user && current_user == user
        _('Private: only you and the site’s admins can see it. ' \
          '{{reason}}', reason: reason)
      elsif admin?
        _('This request has prominence "requester_only". {{reason}} You can ' \
          'only see it because you are logged in as a super user.',
          reason: reason)
      else
        _('This request has not been published. {{reason}}', reason: reason)
      end
    end

    def sign_in_notice(*args)
      _('If you are the requester, then you may {{sign_in_link}} to view the ' \
        'request.', *args)
    end
  end

  class IncomingMessage::Prominence::Helper < Base # :nodoc:
    def info_request
      prominenceable.info_request
    end

    def hidden_notice
      if admin?
        _('This message has prominence "hidden". {{reason}} You can only see ' \
          'it because you are logged in as a super user.', reason: reason)
      else
        _('This message has not been published. {{reason}}', reason: reason)
      end
    end

    def sign_in_notice(*args)
      _('If you are the requester, then you may {{sign_in_link}} to view the ' \
        'message.', *args)
    end
  end

  ::OutgoingMessage::Prominence::Helper = IncomingMessage::Prominence::Helper

  class FoiAttachment::Prominence::Helper < Base # :nodoc:
    def info_request
      prominenceable.incoming_message.info_request
    end

    def hidden_notice
      if admin?
        _('This attachment has prominence "hidden". {{reason}} You can only ' \
          'see it because you are logged in as a super user.', reason: reason)
      else
        # Not why, which only admins are told: it can be what a check found.
        _('This attachment has not been published.')
      end
    end

    def requester_only_notice
      if current_user && current_user == user
        _('Private: only you and the site’s admins can see it. ' \
          '{{reason}}', reason: reason)
      elsif admin?
        _('This attachment has prominence "requester_only". {{reason}} You ' \
          'can only see it because you are logged in as a super user.',
          reason: reason)
      else
        _('This attachment has not been published. {{reason}}', reason: reason)
      end
    end

    def sign_in_notice(*args)
      _('If you are the requester, then you may {{sign_in_link}} to view the ' \
        'attachment.', *args)
    end
  end
end
