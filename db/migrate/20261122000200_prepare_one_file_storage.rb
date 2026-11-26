class PrepareOneFileStorage < ActiveRecord::Migration[8.1]
  def up
    add_column :raw_emails, :read_at, :datetime
    add_index :raw_emails, :read_at
    execute <<~SQL.squish
      UPDATE raw_emails
      SET read_at = incoming_messages.last_parsed
      FROM incoming_messages
      WHERE incoming_messages.raw_email_id = raw_emails.id
        AND incoming_messages.last_parsed IS NOT NULL
        AND raw_emails.read_at IS NULL
    SQL

    add_column :info_requests, :last_activity_at, :datetime
    add_index :info_requests, :last_activity_at
    execute <<~SQL.squish
      UPDATE info_requests
      SET last_activity_at = GREATEST(
        COALESCE(info_requests.last_public_response_at, info_requests.created_at),
        COALESCE((
          SELECT MAX(incoming_messages.created_at)
          FROM incoming_messages
          WHERE incoming_messages.info_request_id = info_requests.id
        ), info_requests.created_at),
        COALESCE((
          SELECT MAX(outgoing_messages.last_sent_at)
          FROM outgoing_messages
          WHERE outgoing_messages.info_request_id = info_requests.id
            AND outgoing_messages.status = 'sent'
            AND outgoing_messages.last_sent_at IS NOT NULL
        ), info_requests.created_at),
        info_requests.created_at
      )
      WHERE info_requests.last_activity_at IS NULL
    SQL

    add_column :foi_attachments, :black_masked, :boolean,
               null: false, default: false
    execute <<~SQL.squish
      UPDATE foi_attachments
      SET prominence = 'public'
      WHERE (prominence = 'normal' OR prominence = 'requester_only' OR prominence IS NULL)
        AND erased_at IS NULL
        AND id IN (
          SELECT foi_attachment_id
          FROM disclosure_documents
          WHERE state = 'published'
            AND erased_at IS NULL
            AND foi_attachment_id IS NOT NULL
        )
    SQL
    execute <<~SQL.squish
      UPDATE foi_attachments
      SET prominence = 'requester_only'
      WHERE prominence = 'normal' OR prominence IS NULL
    SQL
    change_column_default :foi_attachments, :prominence,
                          from: 'normal', to: 'requester_only'
    change_column_null :foi_attachments, :prominence, false
  end

  def down
    change_column_null :foi_attachments, :prominence, true
    change_column_default :foi_attachments, :prominence,
                          from: 'requester_only', to: 'normal'
    remove_column :foi_attachments, :black_masked

    remove_index :info_requests, :last_activity_at
    remove_column :info_requests, :last_activity_at

    remove_index :raw_emails, :read_at
    remove_column :raw_emails, :read_at
  end
end
