# Comments (annotations) were removed (see doc/FORK.md). A comment is
# someone's writing, and its events are the request's history, so this
# refuses to run while any comment, or any event about one, exists, rather
# than drop them unseen. The rest goes whatever it holds: the users counter
# and the per-request "comments allowed" switch only served comments, the
# comment search partition only holds copies of comment text, and the
# annotations Flipper feature had nothing left to switch. The counts are
# reported. The down recreates the schema, empty, with the feature disabled;
# PostgreSQL adds columns at the end, so info_request_events.comment_id,
# users.comments_count and info_requests.comments_allowed come back last in
# their tables rather than where they were. Everything else matches.
class RemoveComments < ActiveRecord::Migration[8.1]
  class CommentsPresent < StandardError; end

  COMMENT_EVENT_TYPES = %w[
    comment edit_comment hide_comment destroy_comment report_comment
  ].freeze

  def up
    comments = select_value('SELECT COUNT(*) FROM comments').to_i
    types = COMMENT_EVENT_TYPES.map { connection.quote(_1) }.join(', ')
    events = select_value(<<~SQL).to_i
      SELECT COUNT(*) FROM info_request_events
      WHERE comment_id IS NOT NULL OR event_type IN (#{types})
    SQL
    if comments.positive? || events.positive?
      raise CommentsPresent,
            "comments has #{comments} row(s) and info_request_events has " \
            "#{events} comment event(s). This migration removes comments " \
            'only when there are none. Export or delete them, then run the ' \
            'migration again. Delete the comment_1 rows in ' \
            'user_info_request_sent_alerts that point at those events ' \
            'first: their foreign key has no ON DELETE action.'
    end

    report('search_documents_comment')
    report('users', 'comments_count <> 0')
    report('info_requests', 'NOT comments_allowed')
    report('flipper_gates', "feature_key = 'annotations'")

    execute "DELETE FROM flipper_gates WHERE feature_key = 'annotations'"
    execute "DELETE FROM flipper_features WHERE key = 'annotations'"

    execute 'DROP TABLE search_documents_comment'
    remove_foreign_key :info_request_events,
                       name: 'fk_info_request_events_comment_id'
    remove_index :info_request_events, :comment_id,
                 name: 'index_info_request_events_on_comment_id'
    remove_column :info_request_events, :comment_id
    drop_table :comments
    remove_column :users, :comments_count
    remove_column :info_requests, :comments_allowed
  end

  def down
    add_column :info_requests, :comments_allowed, :boolean,
               default: true, null: false
    add_column :users, :comments_count, :integer, default: 0, null: false

    execute <<~SQL
      CREATE TABLE public.comments (
          id integer NOT NULL,
          user_id integer NOT NULL,
          info_request_id integer,
          body text NOT NULL,
          visible boolean DEFAULT true NOT NULL,
          created_at timestamp without time zone NOT NULL,
          updated_at timestamp without time zone NOT NULL,
          locale text DEFAULT ''::text NOT NULL,
          attention_requested boolean DEFAULT false NOT NULL
      );

      CREATE SEQUENCE public.comments_id_seq
          AS integer
          START WITH 1
          INCREMENT BY 1
          NO MINVALUE
          NO MAXVALUE
          CACHE 1;

      ALTER SEQUENCE public.comments_id_seq OWNED BY public.comments.id;

      ALTER TABLE ONLY public.comments ALTER COLUMN id SET DEFAULT nextval('public.comments_id_seq'::regclass);

      ALTER TABLE ONLY public.comments
          ADD CONSTRAINT comments_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.comments
          ADD CONSTRAINT fk_comments_info_request FOREIGN KEY (info_request_id) REFERENCES public.info_requests(id);

      ALTER TABLE ONLY public.comments
          ADD CONSTRAINT fk_comments_user FOREIGN KEY (user_id) REFERENCES public.users(id);

      ALTER TABLE public.info_request_events ADD COLUMN comment_id integer;

      CREATE INDEX index_info_request_events_on_comment_id ON public.info_request_events USING btree (comment_id);

      ALTER TABLE ONLY public.info_request_events
          ADD CONSTRAINT fk_info_request_events_comment_id FOREIGN KEY (comment_id) REFERENCES public.comments(id);

      CREATE TABLE search_documents_comment
        PARTITION OF search_documents FOR VALUES IN ('Comment');
    SQL

    execute <<~SQL
      INSERT INTO flipper_features (key, created_at, updated_at)
      SELECT 'annotations', NOW(), NOW()
      WHERE NOT EXISTS (
        SELECT 1 FROM flipper_features WHERE key = 'annotations'
      )
    SQL
  end

  private

  def report(table, condition = 'TRUE')
    count = select_value("SELECT COUNT(*) FROM #{table} WHERE #{condition}")
    say "#{table}: #{count} row(s) affected (#{condition})"
  end
end
