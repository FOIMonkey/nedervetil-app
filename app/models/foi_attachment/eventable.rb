# Logs InfoRequestEvent entries when FoiAttachment visibility changes.
module FoiAttachment::Eventable
  extend ActiveSupport::Concern

  included do
    delegate :log_event, to: :info_request
  end

  def update_and_log_event(event: {}, **params)
    return false unless update(params)

    log_prominence_event(event)
  end

  def update_and_log_event!(event: {}, **params)
    transaction do
      update!(params)
      log_prominence_event(event)
    end
  end

  private

  def log_prominence_event(event)
    log_event(
      'edit_attachment',
      event.merge(
        attachment_id: id,
        old_prominence: prominence_previously_was,
        prominence: prominence,
        old_prominence_reason: prominence_reason_previously_was,
        prominence_reason: prominence_reason
      )
    )
  end
end
