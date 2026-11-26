require 'spec_helper'

# Without declared precision, PostgreSQL stores microseconds while Rails keeps
# nanoseconds in memory; association inversing then marks a reloaded record
# dirty and breaks with_lock. Read pg_attribute.atttypmod directly because
# information_schema.columns reports precision 6 even when undeclared.
RSpec.describe 'Timestamp column precision' do
  let(:undeclared) do
    ActiveRecord::Base.connection.select_rows(<<~SQL)
      SELECT c.relname, a.attname
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = current_schema()
        AND c.relkind IN ('r', 'p')
        AND a.attnum > 0
        AND NOT a.attisdropped
        AND a.atttypid IN ('timestamp'::regtype, 'timestamptz'::regtype)
        AND a.atttypmod <> 6
      ORDER BY 1, 2
    SQL
  end

  it 'gives every timestamp column precision 6' do
    expect(undeclared.map { |table, column| "#{table}.#{column}" }).to be_empty
  end
end
