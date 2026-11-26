class CreateIncomingAttentionOptOuts < ActiveRecord::Migration[8.1]
  def change
    # One row per account that asked for its new replies not to be read by AI.
    create_table :incoming_attention_opt_outs do |t|
      t.references :user, null: false, index: { unique: true }, foreign_key: { on_delete: :cascade }
      t.timestamps
    end
  end
end
