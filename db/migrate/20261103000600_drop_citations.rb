# Citations were removed (see doc/FORK.md). This refuses to drop the table
# while any citation exists, so it can never destroy one. Their search
# partition goes too. The down recreates both as they were, so a source
# rollback still matches the schema.
class DropCitations < ActiveRecord::Migration[8.1]
  class CitationsPresent < StandardError; end

  def up
    count = select_value('SELECT COUNT(*) FROM citations').to_i
    if count.positive?
      raise CitationsPresent,
            "citations has #{count} row(s). This migration drops the " \
            'table only when it is empty. Export or delete the citations, ' \
            'then run the migration again.'
    end

    execute 'DROP TABLE search_documents_citation'
    drop_table :citations
  end

  def down
    execute <<~SQL
      CREATE TABLE public.citations (
          id bigint NOT NULL,
          user_id bigint,
          citable_type character varying,
          citable_id bigint,
          source_url character varying,
          type character varying,
          created_at timestamp without time zone NOT NULL,
          updated_at timestamp without time zone NOT NULL,
          title character varying,
          description text
      );

      CREATE SEQUENCE public.citations_id_seq
          START WITH 1
          INCREMENT BY 1
          NO MINVALUE
          NO MAXVALUE
          CACHE 1;

      ALTER SEQUENCE public.citations_id_seq OWNED BY public.citations.id;

      ALTER TABLE ONLY public.citations ALTER COLUMN id SET DEFAULT nextval('public.citations_id_seq'::regclass);

      ALTER TABLE ONLY public.citations
          ADD CONSTRAINT citations_pkey PRIMARY KEY (id);

      CREATE INDEX index_citations_on_citable_type_and_citable_id ON public.citations USING btree (citable_type, citable_id);

      CREATE INDEX index_citations_on_user_id ON public.citations USING btree (user_id);

      ALTER TABLE ONLY public.citations
          ADD CONSTRAINT fk_rails_f81b244ac7 FOREIGN KEY (user_id) REFERENCES public.users(id);
    SQL
    execute <<~SQL
      CREATE TABLE search_documents_citation
        PARTITION OF search_documents FOR VALUES IN ('Citation');
    SQL
  end
end
