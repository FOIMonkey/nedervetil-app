require 'spec_helper'
require Rails.root.join('db/migrate/20261104000400_drop_insights').to_s

# DDL is transactional in PostgreSQL, so each example's schema changes roll
# back with its transaction.
RSpec.describe DropInsights do
  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { migration.public_send(direction) }
  end

  def columns
    connection.columns(:insights).to_h do |column|
      [column.name, [column.sql_type, column.null, column.default]]
    end
  end

  def insert_insight
    request = FactoryBot.create(:info_request)
    connection.execute(<<~SQL)
      INSERT INTO insights (info_request_id, model, temperature,
                            prompt_template, created_at, updated_at)
      VALUES (#{request.id}, 'llama', 0.3, '[initial_request]', NOW(), NOW())
    SQL
  end

  def flag_rows
    connection.select_value(<<~SQL)
      SELECT (SELECT COUNT(*) FROM flipper_features WHERE key = 'insights') +
             (SELECT COUNT(*) FROM flipper_gates WHERE feature_key = 'insights')
    SQL
  end

  before { migrate(:down) unless connection.table_exists?(:insights) }

  it 'goes down and up on an empty table' do
    migrate(:up)
    expect(connection.table_exists?(:insights)).to eq(false)

    migrate(:down)
    expect(connection.table_exists?(:insights)).to eq(true)
    expect(columns).to eq(
      'id' => ['bigint', false, nil],
      'info_request_id' => ['bigint', true, nil],
      'model' => ['character varying', true, nil],
      'temperature' => ['numeric(8,2)', true, nil],
      'prompt_template' => ['text', true, nil],
      'output' => ['jsonb', true, nil],
      'created_at' => ['timestamp(6) without time zone', false, nil],
      'updated_at' => ['timestamp(6) without time zone', false, nil]
    )
    expect(connection.primary_key(:insights)).to eq('id')
    expect(connection.default_sequence_name(:insights, 'id')).
      to eq('public.insights_id_seq')
    expect(connection.indexes(:insights).map { [_1.name, _1.columns] }).
      to eq([['index_insights_on_info_request_id', ['info_request_id']]])
    foreign_keys = connection.foreign_keys(:insights).map do |key|
      [key.name, key.to_table, key.column, key.on_delete]
    end
    expect(foreign_keys).
      to eq([['fk_rails_ca5c27d73a', 'info_requests', 'info_request_id', nil]])

    migrate(:up)
    expect(connection.table_exists?(:insights)).to eq(false)
  end

  it 'refuses to drop the table while it has insights, and keeps them' do
    insert_insight

    expect { migrate(:up) }.to raise_error(
      DropInsights::InsightsPresent,
      /insights has 1 row\(s\).*only when it is empty/
    )
    expect(connection.table_exists?(:insights)).to eq(true)
    expect(connection.select_value('SELECT COUNT(*) FROM insights')).to eq(1)
  end

  it 'deletes the insights feature flag and leaves other flags alone' do
    backend = Flipper.new(Flipper::Adapters::ActiveRecord.new)
    backend.disable(:insights)
    backend.enable(:insights)
    backend.enable(:alaveteli_pro)
    expect(flag_rows).to eq(2)

    migrate(:up)
    expect(flag_rows).to eq(0)
    expect(backend.enabled?(:alaveteli_pro)).to eq(true)
  end
end
