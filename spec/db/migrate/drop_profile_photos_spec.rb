require 'spec_helper'
require Rails.root.join('db/migrate/20261102000100_drop_profile_photos').to_s

# DDL is transactional in PostgreSQL, so each example's schema changes roll
# back with its transaction.
RSpec.describe DropProfilePhotos do
  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { migration.public_send(direction) }
  end

  def columns
    connection.columns(:profile_photos).to_h do |column|
      [column.name, [column.sql_type, column.null, column.default]]
    end
  end

  def insert_photo
    connection.execute(
      "INSERT INTO profile_photos (data, draft) VALUES ('\\x89504e47', true)"
    )
  end

  before { migrate(:down) unless connection.table_exists?(:profile_photos) }

  it 'goes down and up on an empty table' do
    migrate(:up)
    expect(connection.table_exists?(:profile_photos)).to eq(false)

    migrate(:down)
    expect(connection.table_exists?(:profile_photos)).to eq(true)
    expect(columns).to eq(
      'id' => ['integer', false, nil],
      'data' => ['bytea', false, nil],
      'user_id' => ['integer', true, nil],
      'draft' => ['boolean', false, 'false'],
      'created_at' => ['timestamp without time zone', true, nil],
      'updated_at' => ['timestamp without time zone', true, nil]
    )
    expect(connection.primary_key(:profile_photos)).to eq('id')
    expect(connection.default_sequence_name(:profile_photos, 'id')).
      to eq('public.profile_photos_id_seq')
    foreign_keys = connection.foreign_keys(:profile_photos).map do |key|
      [key.name, key.to_table, key.column, key.on_delete]
    end
    expect(foreign_keys).
      to eq([['fk_profile_photos_user', 'users', 'user_id', nil]])

    migrate(:up)
    expect(connection.table_exists?(:profile_photos)).to eq(false)
  end

  it 'refuses to drop the table while it has photos, and keeps them' do
    insert_photo

    expect { migrate(:up) }.to raise_error(
      DropProfilePhotos::PhotosPresent,
      /profile_photos has 1 row\(s\).*only when it is empty/
    )
    expect(connection.table_exists?(:profile_photos)).to eq(true)
    expect(connection.select_value('SELECT COUNT(*) FROM profile_photos')).
      to eq(1)
  end
end
