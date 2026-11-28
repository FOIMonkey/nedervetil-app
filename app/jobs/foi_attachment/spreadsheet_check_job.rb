# Follow-up for parses with spreadsheets: re-queues Active Storage analysis
# (which an earlier commit-callback error can drop) while the file stays held,
# emailing admins if it still has not run after WAITS.
class FoiAttachment::SpreadsheetCheckJob < ApplicationJob
  queue_as :default

  WAITS = [1.minute, 10.minutes, 1.hour, 6.hours, 18.hours].freeze

  def perform(message_id, attempt = 0)
    message = IncomingMessage.find_by(id: message_id) or return
    unread = message.foi_attachments.includes(file_attachment: :blob).
             select { FoiAttachment::SpreadsheetHold.waiting?(_1) }
    return if unread.empty?

    unread.each { _1.file_blob.analyze_later }
    wait = WAITS[attempt + 1]
    if wait
      self.class.set(wait: wait).perform_later(message_id, attempt + 1)
    else
      unread.each { SpreadsheetHoldMailer.not_read(_1).deliver_now }
    end
  end
end
