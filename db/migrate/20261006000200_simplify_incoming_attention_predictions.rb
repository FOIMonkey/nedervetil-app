class SimplifyIncomingAttentionPredictions < ActiveRecord::Migration[8.1]
  def change
    add_column :incoming_attention_predictions, :attention_override, :string
    add_column :incoming_attention_predictions, :human_reviewed_at, :datetime
    add_column :incoming_attention_predictions, :auto_classified, :boolean, default: false, null: false
    add_index :incoming_attention_predictions, [:status, :updated_at], name: 'incoming_attention_recovery'
  end
end
