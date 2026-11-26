require 'spec_helper'

# A foreign key without an index makes every delete of the row it points at
# scan the table.
RSpec.describe 'Indexes on the features’ foreign keys' do
  # Only a user's deletion looks these up.
  KNOWN_UNINDEXED = %w[
    request_deadline_adjustments.user_id
    request_deadline_closures.user_id
    request_deadline_reminders.user_id
  ].freeze unless defined?(KNOWN_UNINDEXED)

  def feature_tables
    Dir[Rails.root.join('db/migrate/*.rb')].
      select { |file| File.basename(file) >= '20261006' }.
      flat_map do |file|
        File.read(file).scan(/create_table :(\w+)/).flatten
      end.uniq
  end

  def unindexed_foreign_keys
    ActiveRecord::Base.connection.
      select_rows(<<~SQL).map { |table, column| "#{table}.#{column}" }
      SELECT c.conrelid::regclass::text, a.attname
      FROM pg_constraint c
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
      WHERE c.contype = 'f' AND array_length(c.conkey, 1) = 1
        AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.conrelid AND i.indkey[0] = c.conkey[1])
    SQL
  end

  it 'has one leading each foreign key, but for those only a user’s deletion uses' do
    tables = feature_tables
    expect(tables).to include('attachment_management_revisions',
                              'disclosure_documents')
    feature_keys = unindexed_foreign_keys.select do |key|
      tables.include?(key.split('.').first)
    end
    expect(feature_keys).to match_array(KNOWN_UNINDEXED)
  end

  it 'indexes these foreign keys' do
    connection = ActiveRecord::Base.connection
    { attachment_management_revisions: %i[user_id applied_by_id parent_id
                                          info_request_event_id],
      request_deadline_reminders: %i[outgoing_message_id],
      disclosure_pages: %i[document_id],
      disclosure_topic_matches: %i[document_id] }.each do |table, columns|
      columns.each do |column|
        expect(connection.index_exists?(table, column)).
          to be(true), "#{table}.#{column}"
      end
    end
  end
end
