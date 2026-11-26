# Additive storage: legacy credentials remain inert until owner cutover checks.
class AddDeviseAuthentication < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :encrypted_password, :string, null: false, default: ''
    add_column :users, :reset_password_token, :string
    add_column :users, :reset_password_sent_at, :datetime
    add_column :users, :confirmation_token, :string
    add_column :users, :confirmation_sent_at, :datetime
    add_column :users, :confirmed_at, :datetime
    add_column :users, :unconfirmed_email, :string
    add_column :users, :otp_secret, :text
    add_column :users, :consumed_timestep, :bigint
    add_column :users, :otp_required_for_login, :boolean, default: false,
                                                          null: false
    add_column :users, :devise_otp_backup_codes, :string, array: true,
                                                          default: [], null: false
    add_column :users, :authentication_version, :string, default: '',
                                                         null: false
    add_column :users, :credential_reset_required, :boolean, default: false,
                                                             null: false
    add_index :users, :reset_password_token, unique: true
    add_index :users, :confirmation_token, unique: true
    # Never copy passwords, OTP secrets or codes. Keep confirmation facts/IDs.
    execute <<~SQL
      UPDATE users SET confirmed_at = CASE WHEN email_confirmed THEN created_at END,
        authentication_version = gen_random_uuid()::text,
        credential_reset_required = true, otp_required_for_login = true
    SQL
    change_column_default :users, :hashed_password, from: nil, to: ''

    create_table :authentication_returns do |t|
      t.string :token_digest, null: false
      t.text :path, null: false
      t.references :user, foreign_key: true
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.timestamps
    end
    add_index :authentication_returns, :token_digest, unique: true

    create_table :pending_request_drafts do |t|
      t.string :browser_digest, null: false
      t.references :intended_user, foreign_key: { to_table: :users }
      t.text :payload, null: false
      t.datetime :expires_at, null: false
      t.datetime :claimed_at
      t.references :draft_info_request, foreign_key: { on_delete: :nullify }
      t.timestamps
    end
    add_index :pending_request_drafts, :browser_digest, unique: true

    create_table :authentication_enrolments do |t|
      t.references :user, null: false, foreign_key: true
      t.string :token_digest, null: false
      t.string :credential_state, null: false
      t.text :secret, null: false
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.timestamps
    end
    add_index :authentication_enrolments, :token_digest, unique: true

    create_table :pending_email_changes do |t|
      t.references :user, null: false, foreign_key: true
      t.string :token_digest, null: false
      t.string :credential_state, null: false
      t.string :old_email, null: false
      t.string :new_email, null: false
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.timestamps
    end
    add_index :pending_email_changes, :token_digest, unique: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          'Preserve current credentials and drafts; use a reviewed forward repair.'
  end
end
