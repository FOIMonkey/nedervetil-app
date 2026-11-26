require 'spec_helper'
require Rails.root.join(
  'db/migrate/20261105000933_remove_pro_feature_flags'
).to_s

# Data changes are transactional in PostgreSQL, so each example's changes
# roll back with its transaction.
RSpec.describe RemoveProFeatureFlags do
  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }
  let(:backend) { Flipper.new(Flipper::Adapters::ActiveRecord.new) }

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { migration.public_send(direction) }
  end

  def rows(key)
    connection.select_value(<<~SQL)
      SELECT (SELECT COUNT(*) FROM flipper_features
              WHERE key = #{connection.quote(key)}) +
             (SELECT COUNT(*) FROM flipper_gates
              WHERE feature_key = #{connection.quote(key)})
    SQL
  end

  it 'deletes the flags only Pro used, and leaves the others' do
    user = FactoryBot.create(:user)
    backend.enable(:alaveteli_pro)
    backend.enable_actor(:notifications, user)
    backend.enable_actor(:pro_batch_category_ui, user)
    backend.enable_actor(:database_backed_alerts, user)

    migrate(:up)

    %w[alaveteli_pro notifications pro_batch_category_ui].each do |key|
      expect(rows(key)).to eq(0), key
    end
    expect(backend.enabled?(:database_backed_alerts, user)).to eq(true)
  end

  it 'switches the batch category picker on for everyone on down' do
    migrate(:up)
    migrate(:down)

    expect(backend.enabled?(:pro_batch_category_ui)).to eq(true)
  end
end
