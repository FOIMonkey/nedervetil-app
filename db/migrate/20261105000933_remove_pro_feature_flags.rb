# Pro-only Flipper flags (alaveteli_pro, notifications, pro_batch_category_ui)
# are removed now that every account shares the unified inbox.
class RemoveProFeatureFlags < ActiveRecord::Migration[8.1]
  FLAGS = %w[alaveteli_pro notifications pro_batch_category_ui].freeze

  def up
    return unless table_exists?(:flipper_features)

    keys = FLAGS.map { |flag| connection.quote(flag) }.join(', ')
    execute "DELETE FROM flipper_gates WHERE feature_key IN (#{keys})"
    execute "DELETE FROM flipper_features WHERE key IN (#{keys})"
  end

  def down
    return unless table_exists?(:flipper_features)

    execute <<~SQL
      INSERT INTO flipper_features (key, created_at, updated_at)
      VALUES ('pro_batch_category_ui', NOW(), NOW())
    SQL
    execute <<~SQL
      INSERT INTO flipper_gates (feature_key, key, value, created_at, updated_at)
      VALUES ('pro_batch_category_ui', 'boolean', 'true', NOW(), NOW())
    SQL
  end
end
