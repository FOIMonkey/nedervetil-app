class CreateIncomingAttentionInstantEmails < ActiveRecord::Migration[8.1]
  def change
    # One row per account that chose an email for each reply instead of only the daily summary.
    create_table :incoming_attention_instant_emails do |t|
      t.references :user, null: false, index: { unique: true }, foreign_key: { on_delete: :cascade }
      t.timestamps
    end
  end
end
