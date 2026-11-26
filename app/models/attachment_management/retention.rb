module AttachmentManagement
  # Draft records stay (status, digests, who and when) as the audit; their
  # files don't. Closing a draft already deletes its file; this catches any
  # left behind.
  class Retention
    Result = Struct.new(:expired, :files_deleted, :previews_deleted,
                        keyword_init: true)

    def run(now: Time.current)
      result = Result.new(expired: 0, files_deleted: 0, previews_deleted: 0)

      Revision.open.
        where(updated_at: ...(now - AttachmentManagement.draft_retention)).
        find_each do |draft|
          result.expired += 1 if draft.leave!('expired')
        end

      Revision.where.not(status: %w[processing ready]).
        joins(:output_attachment).find_each do |draft|
          draft.with_status_lock(Revision::STATUSES - %w[processing ready]) do
            next unless draft.output.attached?

            draft.output.purge
            result.files_deleted += 1
          end
        end

      result.previews_deleted = Previews.expire(
        older_than: now - AttachmentManagement.preview_retention
      )
      result
    end
  end
end
