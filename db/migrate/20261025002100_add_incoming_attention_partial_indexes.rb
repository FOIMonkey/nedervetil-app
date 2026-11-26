class AddIncomingAttentionPartialIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # Effective.unresolved's check for automatic classifications, and the outcome
  # sweep (Recovery.outcomes): each read the whole table without these.
  def change
    add_index :incoming_attention_predictions, :response_event_id,
              where: 'auto_classified',
              name: 'incoming_attention_auto_classified_event',
              algorithm: :concurrently
    add_index :incoming_attention_predictions, :outcome_checked_at,
              where: "outcome_status IN ('pending', 'running')",
              name: 'incoming_attention_outcome_sweep',
              algorithm: :concurrently
  end
end
