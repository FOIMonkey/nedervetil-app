class VersionPublicBody < ActiveRecord::Migration[4.2] # 1.2
  def self.up
    unless column_exists?(:public_bodies, :version)
      add_column :public_bodies, :version, :integer
    end

    # On the connection, as the old versioning gem did, so the id is a
    # bigserial as on existing databases.
    connection.create_table :public_body_versions do |t|
      t.integer :public_body_id
      t.integer :version
      t.text :name
      t.text :short_name
      t.text :request_email
      t.text :complaint_email
    end
    add_index :public_body_versions, :public_body_id

    add_timestamps(:public_body_versions, null: false)
  end

  def self.down
    drop_table :public_body_versions
  end
end
