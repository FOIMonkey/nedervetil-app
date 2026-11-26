# The AI insights were removed (see doc/FORK.md). Each insight kept a prompt
# built from a request's first message and the language model's answer, so
# this refuses to drop a table that holds any. It also deletes the insights
# feature flag that the old initializer recorded on every boot. The down
# recreates the table as it was, so a source rollback still matches the
# schema; the old initializer records the flag again when it boots.
class DropInsights < ActiveRecord::Migration[8.1]
  class InsightsPresent < StandardError; end

  def up
    count = select_value('SELECT COUNT(*) FROM insights').to_i
    if count.positive?
      raise InsightsPresent,
            "insights has #{count} row(s). This migration drops the table " \
            'only when it is empty. Export or delete the insights, then run ' \
            'the migration again.'
    end

    drop_table :insights
    delete_feature_flag
  end

  def down
    create_table :insights do |t|
      t.references :info_request, foreign_key: true
      t.string :model
      t.decimal :temperature, precision: 8, scale: 2
      t.text :prompt_template
      t.jsonb :output
      t.timestamps
    end
  end

  private

  def delete_feature_flag
    return unless table_exists?(:flipper_features)

    execute "DELETE FROM flipper_gates WHERE feature_key = 'insights'"
    execute "DELETE FROM flipper_features WHERE key = 'insights'"
  end
end
