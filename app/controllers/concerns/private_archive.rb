# ApplicationController privacy gate: restricts requests, batches, messages,
# attachments and user accounts to their owners and active admins, and adds
# private, no-store cache headers.
module PrivateArchive
  SWITCHED_OFF_PREFIXES = %w[active_storage/].freeze

  private

  def private_archive_no_store
    response.headers['cache-control'] = 'private, no-store'
  end

  def private_archive_policy
    response.headers['cache-control'] = 'private, no-store'
    private_archive_named_request
    private_archive_named_batch
    private_archive_page
  end

  def private_archive_named_request
    return if controller_path.start_with?('admin')

    titles = [params[:request_url_title], params[:url_title]]
    titles.compact.uniq.each do |title|
      private_archive_request!(InfoRequest.find_by_url_title!(title))
    end
  end

  def private_archive_named_batch
    return unless params[:info_request_batch_id]
    return if controller_path.start_with?('admin')

    batch = InfoRequestBatch.find(params[:info_request_batch_id])
    raise ActiveRecord::RecordNotFound unless can?(:read, batch)
  end

  def private_archive_page
    path = controller_path
    action = action_name
    if path == 'user' && action == 'show'
      private_archive_user_page
    elsif private_archive_switched_off?
      private_archive_switched_off
    elsif path == 'request'
      private_archive_request_page
    elsif path == 'attachments'
      private_archive_attachment
    elsif path == 'outgoing_messages/delivery_statuses'
      # Checked here rather than left to core, whose hidden page would confirm
      # that someone else's message exists.
      message = OutgoingMessage.find(params[:outgoing_message_id])
      private_archive_request!(message.info_request)
    elsif path == 'attachment_masks'
      private_archive_attachment_mask
    elsif path == 'info_request_batch' && action == 'show'
      batch = InfoRequestBatch.find(params[:id])
      raise ActiveRecord::RecordNotFound unless can?(:read, batch)
    elsif path == 'public_body' && action == 'show' &&
          defined?(Disclosures::Search)
      private_archive_body_page
    end
  end

  def private_archive_user_page
    if action_name == 'show'
      simple = MySociety::Format.simplify_url_part(params[:url_name], 'user')
      if simple != params[:url_name]
        return redirect_to(url_name: simple, status: :moved_permanently)
      end
    end
    private_archive_account!(private_archive_user)
  end

  def private_archive_user
    User.where(email_confirmed: true).friendly.find(params[:url_name])
  end

  def private_archive_switched_off?
    SWITCHED_OFF_PREFIXES.any? { |prefix| controller_path.start_with?(prefix) }
  end

  def private_archive_switched_off
    raise ActiveRecord::RecordNotFound
  end

  def private_archive_request_page
    return unless params[:info_request_event_id]

    event = InfoRequestEvent.find(params[:info_request_event_id])
    private_archive_request!(event.info_request)
  end

  # Refuse attachment URLs without a request_url_title (checked above).
  def private_archive_attachment
    return if params[:request_url_title]

    raise ActiveRecord::RecordNotFound
  end

  def private_archive_attachment_mask
    attachment = GlobalID::Locator.locate_signed(params[:id])
    return if attachment.is_a?(FoiAttachment) && can?(:read, attachment)

    raise ActiveRecord::RecordNotFound
  end

  def private_archive_body_page
    simple = MySociety::Format.simplify_url_part(params[:url_name], 'body')
    if simple != params[:url_name]
      return redirect_to(url_name: simple, status: :moved_permanently)
    end

    body = PublicBody.find_by_url_name_with_historic(params[:url_name])
    raise ActiveRecord::RecordNotFound unless body

    if body.url_name && body.url_name != params[:url_name]
      return redirect_to(url_name: body.url_name)
    end

    unless request.format.html?
      return redirect_to(
        disclosure_documents_path(body: body.url_name, format: params[:format])
      )
    end

    @public_body = body
    @title = body.name
    @search = Disclosures::Search.new(body: body.url_name, q: params[:q],
                                      page: params[:page])
    render template: 'public_body/documents'
  end

  def private_archive_account!(target)
    raise ActiveRecord::RecordNotFound unless can?(:read, target)
  end

  def private_archive_request!(record)
    raise ActiveRecord::RecordNotFound unless can?(:read, record)
  end

  # Lookup + authorize InfoRequest; always 404 on missing or unauthorized.
  def find_info_request!(action, id: nil, url_title: nil)
    request = if url_title
                InfoRequest.find_by(url_title: url_title.to_s)
              else
                InfoRequest.find_by(id: id.to_s)
              end
    raise ActiveRecord::RecordNotFound unless request && can?(action, request)

    request
  end
end
