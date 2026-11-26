class CreateIncomingAttentionPredictions < ActiveRecord::Migration[8.1]
  def change
    create_table :incoming_attention_predictions do |t|
      t.bigint :incoming_message_id, null: false
      t.bigint :info_request_id, null: false
      t.bigint :response_event_id
      t.string :status, null: false, default: 'pending'
      t.string :route
      t.boolean :needs_check
      t.boolean :eligible, null: false, default: false
      t.boolean :coverage_verified, null: false, default: false
      t.jsonb :native_response
      t.jsonb :restrictions, null: false, default: []
      t.string :input_fingerprint
      t.string :state_sha256
      t.string :source_revision_sha256
      t.string :source_signature
      t.string :config_fingerprint
      t.string :error_code
      t.bigint :generation, null: false, default: 0
      t.integer :attempts, null: false, default: 0
      t.string :lease_token
      t.datetime :lease_expires_at
      t.datetime :predicted_at
      t.timestamps
    end
    add_index :incoming_attention_predictions, :incoming_message_id,
              unique: true,
              name: 'incoming_attention_prediction_message'
    add_index :incoming_attention_predictions, :info_request_id
    add_foreign_key :incoming_attention_predictions, :incoming_messages, on_delete: :cascade
    add_foreign_key :incoming_attention_predictions, :info_requests, on_delete: :cascade
  end
end
