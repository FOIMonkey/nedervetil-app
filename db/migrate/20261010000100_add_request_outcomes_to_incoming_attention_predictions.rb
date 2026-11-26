class AddRequestOutcomesToIncomingAttentionPredictions < ActiveRecord::Migration[8.1]
  def change
    add_column :incoming_attention_predictions, :outcome_status, :string
    add_column :incoming_attention_predictions, :outcome_attempts, :integer, default: 0, null: false
    add_column :incoming_attention_predictions, :outcome_scores, :jsonb
    add_column :incoming_attention_predictions, :outcome_signals, :jsonb
    add_column :incoming_attention_predictions, :outcome_call, :string
    add_column :incoming_attention_predictions, :outcome_applied_state, :string
    add_column :incoming_attention_predictions, :outcome_overridden_from, :string
    add_column :incoming_attention_predictions, :outcome_checked_at, :datetime
  end
end
