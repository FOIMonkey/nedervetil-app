# Copyright (c) 2007 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

# URL, path, link and DOM-ID helpers for requests, messages, attachments,
# authorities, users and locale switching, shared by views, controllers,
# mailers and models.
module LinkToHelper
  # Links to various models

  # Requests
  def request_url(info_request, options = {})
    show_request_url(info_request.url_title, options)
  end

  def request_path(info_request, options = {})
    request_url(info_request, options.merge(only_path: true))
  end

  def request_link(info_request)
    link_to info_request.title, request_path(info_request)
  end

  def request_details_path(info_request)
    details_request_path(url_title: info_request.url_title)
  end

  # Incoming / outgoing messages
  def incoming_message_url(incoming_message, options = {})
    message_url(incoming_message, options)
  end

  def incoming_message_path(incoming_message, options = {})
    message_path(incoming_message, options)
  end

  def outgoing_message_url(outgoing_message, options = {})
    message_url(outgoing_message, options)
  end

  def outgoing_message_path(outgoing_message, options = {})
    message_path(outgoing_message, options)
  end

  def foi_attachment_url(foi_attachment, options = {})
    incoming_message_url(
      foi_attachment.incoming_message,
      options.merge(anchor: dom_id(foi_attachment))
    )
  end

  def foi_attachment_path(foi_attachment, options = {})
    foi_attachment_url(foi_attachment, options.merge(only_path: true))
  end

  # Used in mailers where we want to give a link to a new response. Every
  # request is private to its requester, so the link goes through sign-in.
  def new_response_url(_info_request, incoming_message)
    message_url = incoming_message_url(incoming_message, cachebust: true)
    signin_url(r: message_url)
  end

  # Respond to request
  def respond_to_last_url(info_request, options = {})
    last_response = info_request.last_public_response
    if last_response.nil?
      new_request_followup_url(info_request.url_title, options)
    else
      new_request_incoming_followup_url(
        info_request.url_title,
        options.merge(incoming_message_id: last_response.id)
      )
    end
  end

  def respond_to_last_path(info_request, options = {})
    respond_to_last_url(info_request, options.merge(only_path: true))
  end

  # Public bodies
  def public_body_url(public_body, options = {})
    if public_body.url_name.nil?
      ''
    else
      show_public_body_url(options.merge(url_name: public_body.url_name))
    end
  end

  def public_body_path(public_body, options = {})
    public_body_url(public_body, options.merge(only_path: true))
  end

  def public_body_link(public_body)
    link_to public_body.name, public_body_path(public_body)
  end

  def public_body_link_absolute(public_body) # e.g. for in RSS
    link_to public_body.name, public_body_url(public_body)
  end

  # Users
  def user_url(user, options = {})
    show_user_url(options.merge(url_name: user.url_name))
  end

  def user_path(user, options = {})
    user_url(user, options.merge(only_path: true))
  end

  def user_link_absolute(user, text = nil)
    text ||= user.name
    link_to text, user_url(user)
  end

  def user_link(user, text = nil)
    text ||= user.name
    link_to text, user_path(user)
  end

  def user_link_for_request(request)
    link_to request.user.name, user_path(request.user)
  end

  def user_admin_link_for_request(request, text = nil)
    link_to(text || request.user.name, admin_user_url(request.user))
  end

  def request_user_link_absolute(request)
    user_link_absolute(request.user, request.safe_from_name)
  end

  def request_user_link(request)
    user_link(request.user, request.safe_from_name)
  end

  def user_admin_link(user, name = "admin")
    link_to name, admin_user_url(user)
  end

  def unhappy_url(info_request = nil, options = {})
    if info_request.nil?
      help_general_url(options.merge(template: 'unhappy'))
    else
      help_unhappy_url(options.merge(url_title: info_request.url_title))
    end
  end

  def current_path_without_locale
    path_with_query(safe_request_path,
                    request.query_parameters.except('locale'))
  end

  def current_path_with_locale(locale)
    path_with_query(safe_request_path,
                    request.query_parameters.merge('locale' => locale))
  end

  def incoming_message_dom_id(incoming_message)
    body = incoming_message.get_main_body_text_part
    dom_id(body) if body
  end

  private

  def safe_request_path
    "/#{request.path_info.to_s.sub(%r{\A[/\\]+}, '')}"
  end

  def path_with_query(path, query)
    encoded = query.to_query
    encoded.empty? ? path : "#{path}?#{encoded}"
  end

  # Private: Generate a request_url linking to the new correspondence
  def message_url(message, options = {})
    anchor = options[:anchor]
    anchor ||= dom_id(message)

    return "##{anchor}" if options[:anchor_only]

    default_options = { anchor: anchor }

    default_options[:nocache] = anchor if options.delete(:cachebust)

    request_url(message.info_request, options.merge(default_options))
  end

  def message_path(message, options = {})
    message_url(message, options.merge(only_path: true))
  end

  def dom_id(record, prefix = nil)
    case record
    when IncomingMessage
      param_key = 'incoming'
    when OutgoingMessage
      param_key = 'outgoing'
    when FoiAttachment
      param_key = 'attachment'
    else
      return super
    end

    [prefix, param_key, record.to_param].compact.join('-')
  end
end
