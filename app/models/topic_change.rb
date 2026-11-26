# Append-only audit log for topic content (TopicPage, its rows, TopicDataset).
# Stores `field => [before, after]` changesets; newest id is content version.
class TopicChange < ApplicationRecord
  ACTIONS = %w[create update destroy].freeze
  # TOPC; PostgreSQL keeps two-argument lock keys apart from bigint keys.
  TURN = 0x544F5043

  belongs_to :user, optional: true
  belongs_to :record, polymorphic: true, optional: true

  validates :action, inclusion: { in: ACTIONS }

  # Includes deleted rows via topic_page_id recorded in their changeset.
  scope :for_topic_page, ->(page) {
    rows = where("changeset -> 'topic_page_id' @> ?::jsonb", page.id.to_s).
           where.not(record_type: 'TopicPage').select(:record_type, :record_id)
    where(record_type: 'TopicPage', record_id: page.id).
      or(where("(record_type, record_id) IN (#{rows.to_sql})"))
  }

  after_create { Current.topic_content = nil }
  after_rollback { Current.topic_content = nil }

  # Serializes topic writes until commit/rollback so change ids stay monotonic
  # with commit order and no write commits unseen below a newer version.
  def self.take_turn
    connection.execute("SELECT pg_advisory_xact_lock(#{TURN}, 0)")
  end

  def readonly?
    persisted? || super
  end
end
