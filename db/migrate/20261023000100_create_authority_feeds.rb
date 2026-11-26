# Spending is a link from a spending: tag, not imported (formats vary too much to compare).
class CreateAuthorityFeeds < ActiveRecord::Migration[8.1]
  FEEDS = [
    { key: 'sic_statistics', heading: 'FOI record', tab: 'foi_record', kind: 'figures', position: 10,
      updates: 'yearly', source_line: 'From the Scottish Information Commissioner',
      licence: 'Open Government Licence v3.0', spotlights: %w[on_time requests] },
    { key: 'sic_decisions', heading: 'Commissioner decisions', tab: 'foi_record', kind: 'decisions', position: 20,
      updates: 'daily', source_line: 'From the Scottish Information Commissioner', licence: nil, spotlights: %w[count] },
    { key: 'ico_decisions', heading: 'ICO decisions', tab: 'foi_record', kind: 'decisions', position: 30,
      updates: 'daily', source_line: 'From the Information Commissioner’s Office',
      licence: 'Open Government Licence v3.0', spotlights: [] }
  ].freeze

  LINKS = [
    # The whole address is the tag's value: spending:https://…
    { label: 'Spending data', url_template: '{value}', tag: 'spending', position: 5 },
    { label: 'Local statistics', url_template: 'https://www.ons.gov.uk/explore-local-statistics/areas/{value}',
      tag: 'gss', position: 10 },
    { label: 'Wikidata', url_template: 'https://www.wikidata.org/wiki/{value}', tag: 'wikidata', position: 20 }
  ].freeze

  def change
    create_table :authority_feeds do |t|
      t.string :key, null: false, index: { unique: true }
      t.string :heading, null: false
      t.string :tab, null: false
      t.string :kind, null: false
      t.integer :position, null: false, default: 0
      t.string :updates, null: false, default: 'weekly'
      t.string :source_line
      t.string :licence
      # Space-separated; the feed shows only for authorities with all of them. Blank: any.
      t.string :only_tags
      t.jsonb :spotlights, null: false, default: []
      t.datetime :checked_at
      t.string :check_error
      t.datetime :hidden_at
      t.timestamps
    end

    create_table :authority_feed_imports do |t|
      t.references :authority_feed, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, foreign_key: { on_delete: :nullify }
      t.string :filename
      t.string :state, null: false, default: 'preview'
      t.text :body
      t.integer :rows_count, null: false, default: 0
      t.integer :added_count, null: false, default: 0
      t.integer :updated_count, null: false, default: 0
      t.integer :skipped_count, null: false, default: 0
      t.datetime :applied_at
      t.timestamps
    end

    create_table :authority_feed_items do |t|
      t.references :authority_feed, null: false, index: false, foreign_key: { on_delete: :cascade }
      # Empty until the source's name for the authority is matched (AuthorityFeeds::Matcher).
      t.references :public_body, index: false, foreign_key: { on_delete: :cascade }
      t.string :authority_name
      t.date :occurred_on, null: false
      t.string :reference
      t.text :title
      t.string :outcome
      t.text :url
      t.string :dedupe_key, null: false
      t.references :authority_feed_import, foreign_key: { on_delete: :nullify }
      t.datetime :hidden_at
      t.timestamps
      t.index %i[authority_feed_id dedupe_key], unique: true
      t.index %i[public_body_id authority_feed_id occurred_on]
      t.index %i[authority_feed_id authority_name], where: 'public_body_id IS NULL', name: 'index_authority_feed_items_unmatched'
    end

    create_table :authority_feed_figures do |t|
      t.references :authority_feed, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.references :public_body, index: false, foreign_key: { on_delete: :cascade }
      # "body:<id>" or "sector:<name>" (a sector row, such as all of Scotland, for comparison).
      t.string :scope_key, null: false
      t.string :period, null: false
      t.string :metric, null: false
      t.decimal :value, precision: 16, scale: 2, null: false
      t.timestamps
      t.index %i[authority_feed_id scope_key period metric], unique: true, name: 'index_authority_feed_figures_unique'
      t.index %i[public_body_id authority_feed_id]
    end

    create_table :authority_feed_summaries do |t|
      t.references :authority_feed, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.references :public_body, null: false, foreign_key: { on_delete: :cascade }
      t.integer :items_count, null: false, default: 0
      t.date :latest_on
      t.string :latest_period
      # Worked out when rows change, so pages never aggregate.
      t.jsonb :periods, null: false, default: {}
      # From the source, not worked out: "Figures include the licensing board". Kept by rebuilds.
      t.string :note
      t.timestamps
      t.index %i[authority_feed_id public_body_id], unique: true, name: 'index_authority_feed_summaries_unique'
    end

    create_table :authority_feed_aliases do |t|
      t.references :authority_feed, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.references :public_body, null: false, foreign_key: { on_delete: :cascade }
      t.timestamps
      t.index %i[authority_feed_id name], unique: true
    end

    create_table :authority_links do |t|
      t.string :label, null: false
      t.string :url_template, null: false
      t.string :tag
      t.integer :position, null: false, default: 0
      t.timestamps
    end

    reversible do |dir|
      dir.up do
        now = Time.current
        FEEDS.each do |feed|
          execute(<<~SQL.squish)
            INSERT INTO authority_feeds (key, heading, tab, kind, position, updates, source_line, licence, spotlights, created_at, updated_at)
            VALUES (#{[feed[:key], feed[:heading], feed[:tab], feed[:kind]].map { |v| quote(v) }.join(', ')},
                    #{feed[:position]}, #{quote(feed[:updates])}, #{quote(feed[:source_line])}, #{quote(feed[:licence])},
                    #{quote(feed[:spotlights].to_json)}::jsonb, #{quote(now)}, #{quote(now)})
          SQL
        end
        LINKS.each do |link|
          execute(<<~SQL.squish)
            INSERT INTO authority_links (label, url_template, tag, position, created_at, updated_at)
            VALUES (#{quote(link[:label])}, #{quote(link[:url_template])}, #{quote(link[:tag])}, #{link[:position]},
                    #{quote(now)}, #{quote(now)})
          SQL
        end
      end
    end
  end

  private

  def quote(value)
    connection.quote(value)
  end
end
