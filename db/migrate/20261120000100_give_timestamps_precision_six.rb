# Gives precision 6 to the timestamp columns that older migrations made without
# one, as Rails gives new columns. PostgreSQL already stores microseconds in
# them, so only the declared type changes: no table or index is rewritten,
# though each table is locked briefly. With the precision declared, Rails
# rounds values in memory as PostgreSQL does (spec/db/timestamp_precision_spec).
class GiveTimestampsPrecisionSix < ActiveRecord::Migration[8.1]
  COLUMNS = {
    active_storage_attachments: %i(created_at),
    active_storage_blobs: %i(created_at),
    announcement_dismissals: %i(created_at updated_at),
    announcement_translations: %i(created_at updated_at),
    announcements: %i(created_at updated_at),
    censor_rules: %i(created_at updated_at),
    draft_info_request_batches: %i(created_at updated_at),
    draft_info_requests: %i(created_at updated_at),
    flipper_features: %i(created_at updated_at),
    flipper_gates: %i(created_at updated_at),
    foi_attachments: %i(created_at updated_at),
    has_tag_string_tags: %i(created_at updated_at),
    holidays: %i(created_at updated_at),
    incoming_message_errors: %i(created_at retry_at updated_at),
    incoming_messages: %i(created_at last_parsed sent_at updated_at),
    info_request_batches: %i(created_at sent_at updated_at),
    info_request_events: %i(created_at last_described_at updated_at),
    info_requests: %i(
      created_at last_event_time last_public_response_at updated_at
    ),
    mail_server_log_dones: %i(created_at last_stat updated_at),
    mail_server_logs: %i(created_at updated_at),
    notifications: %i(created_at seen_at send_after updated_at),
    outgoing_message_snippets: %i(created_at updated_at),
    outgoing_messages: %i(created_at last_sent_at updated_at),
    post_redirects: %i(created_at updated_at),
    public_bodies: %i(created_at updated_at),
    public_body_categories: %i(created_at updated_at),
    public_body_category_links: %i(created_at updated_at),
    public_body_change_requests: %i(created_at updated_at),
    public_body_headings: %i(created_at updated_at),
    public_body_versions: %i(created_at updated_at),
    raw_emails: %i(created_at erased_at updated_at),
    request_classifications: %i(created_at updated_at),
    request_summaries: %i(
      created_at request_created_at request_updated_at updated_at
    ),
    request_summary_categories: %i(created_at updated_at),
    roles: %i(created_at updated_at),
    spam_addresses: %i(created_at updated_at),
    user_info_request_sent_alerts: %i(created_at updated_at),
    users: %i(
      closed_at created_at email_bounced_at last_daily_track_email
      last_sign_in_at updated_at
    )
  }.freeze

  def up
    change_precision(6)
  end

  def down
    change_precision(nil)
  end

  private

  def change_precision(precision)
    COLUMNS.each do |table, columns|
      change_table table, bulk: true do |t|
        columns.each do |column|
          t.change column, :datetime, precision: precision
        end
      end
    end
  end
end
