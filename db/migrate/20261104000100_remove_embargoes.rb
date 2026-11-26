# Embargoes were removed (see doc/FORK.md): every request stays private to
# its requester, so an embargo could never make one public. An embargo did
# still stop its request's documents being published, so this refuses to run
# while any embargo exists rather than lift that hold unseen. The rest goes
# whatever it holds: embargo extensions only exist with an embargo, Pro
# accounts held nothing but a default embargo length, drafts never kept one,
# and a batch's length only fed its requests' embargoes. The summary category
# for embargoes ending soon goes with its links. The down recreates the
# schema, empty.
class RemoveEmbargoes < ActiveRecord::Migration[8.1]
  class EmbargoesPresent < StandardError; end

  DURATION_TABLES = %i[
    info_request_batches draft_info_requests draft_info_request_batches
  ].freeze

  def up
    count = select_value('SELECT COUNT(*) FROM embargoes').to_i
    if count.positive?
      raise EmbargoesPresent,
            "embargoes has #{count} row(s). Each one stops its request's " \
            'documents being published, so this migration removes ' \
            'embargoes only when there are none. Check those requests, ' \
            'then delete the embargoes (DELETE FROM embargo_extensions; ' \
            'DELETE FROM embargoes;) and run the migration again.'
    end

    report('pro_accounts')
    report('info_request_batches', 'embargo_duration IS NOT NULL')

    execute <<~SQL
      DELETE FROM request_summaries_summary_categories
      WHERE request_summary_category_id IN (
        SELECT id FROM request_summary_categories
        WHERE slug = 'embargo_expiring'
      )
    SQL
    execute "DELETE FROM request_summary_categories " \
            "WHERE slug = 'embargo_expiring'"

    drop_table :embargo_extensions
    drop_table :embargoes
    drop_table :pro_accounts
    DURATION_TABLES.each { |table| remove_column table, :embargo_duration }
  end

  def down
    DURATION_TABLES.each do |table|
      add_column table, :embargo_duration, :string
    end

    execute <<~SQL
      CREATE TABLE public.embargoes (
          id integer NOT NULL,
          info_request_id integer,
          publish_at timestamp without time zone NOT NULL,
          created_at timestamp without time zone NOT NULL,
          updated_at timestamp without time zone NOT NULL,
          embargo_duration character varying,
          expiring_notification_at timestamp without time zone
      );

      CREATE SEQUENCE public.embargoes_id_seq
          AS integer
          START WITH 1
          INCREMENT BY 1
          NO MINVALUE
          NO MAXVALUE
          CACHE 1;

      ALTER SEQUENCE public.embargoes_id_seq OWNED BY public.embargoes.id;

      ALTER TABLE ONLY public.embargoes ALTER COLUMN id SET DEFAULT nextval('public.embargoes_id_seq'::regclass);

      ALTER TABLE ONLY public.embargoes
          ADD CONSTRAINT embargoes_pkey PRIMARY KEY (id);

      CREATE INDEX index_embargoes_on_info_request_id ON public.embargoes USING btree (info_request_id);

      CREATE TABLE public.embargo_extensions (
          id integer NOT NULL,
          embargo_id integer,
          extension_duration character varying,
          created_at timestamp without time zone NOT NULL,
          updated_at timestamp without time zone NOT NULL
      );

      CREATE SEQUENCE public.embargo_extensions_id_seq
          AS integer
          START WITH 1
          INCREMENT BY 1
          NO MINVALUE
          NO MAXVALUE
          CACHE 1;

      ALTER SEQUENCE public.embargo_extensions_id_seq OWNED BY public.embargo_extensions.id;

      ALTER TABLE ONLY public.embargo_extensions ALTER COLUMN id SET DEFAULT nextval('public.embargo_extensions_id_seq'::regclass);

      ALTER TABLE ONLY public.embargo_extensions
          ADD CONSTRAINT embargo_extensions_pkey PRIMARY KEY (id);

      CREATE TABLE public.pro_accounts (
          id integer NOT NULL,
          user_id integer NOT NULL,
          default_embargo_duration character varying,
          created_at timestamp without time zone NOT NULL,
          updated_at timestamp without time zone NOT NULL
      );

      CREATE SEQUENCE public.pro_accounts_id_seq
          AS integer
          START WITH 1
          INCREMENT BY 1
          NO MINVALUE
          NO MAXVALUE
          CACHE 1;

      ALTER SEQUENCE public.pro_accounts_id_seq OWNED BY public.pro_accounts.id;

      ALTER TABLE ONLY public.pro_accounts ALTER COLUMN id SET DEFAULT nextval('public.pro_accounts_id_seq'::regclass);

      ALTER TABLE ONLY public.pro_accounts
          ADD CONSTRAINT pro_accounts_pkey PRIMARY KEY (id);
    SQL

    execute <<~SQL
      INSERT INTO request_summary_categories (slug, created_at, updated_at)
      SELECT 'embargo_expiring', NOW(), NOW()
      WHERE NOT EXISTS (
        SELECT 1 FROM request_summary_categories
        WHERE slug = 'embargo_expiring'
      )
    SQL
  end

  private

  def report(table, condition = 'TRUE')
    count = select_value("SELECT COUNT(*) FROM #{table} WHERE #{condition}")
    say "#{table}: #{count} row(s) affected (#{condition})"
  end
end
