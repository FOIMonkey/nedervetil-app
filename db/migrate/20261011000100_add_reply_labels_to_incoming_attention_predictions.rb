class AddReplyLabelsToIncomingAttentionPredictions < ActiveRecord::Migration[8.1]
  def change
    add_column :incoming_attention_predictions, :reply_labels, :jsonb
  end
end
