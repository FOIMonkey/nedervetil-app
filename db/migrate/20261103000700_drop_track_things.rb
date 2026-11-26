# Tracks (email alerts and feeds for requests, authorities, people and
# searches) were removed (see doc/FORK.md). A track is an alert preference,
# not anyone's content, so the tables go whatever they hold; the count is
# reported. The down recreates the tables and the users column as they were
# (empty), so a source rollback still matches the schema.
class DropTrackThings < ActiveRecord::Migration[8.1]
  def up
    count = select_value('SELECT COUNT(*) FROM track_things').to_i
    say "Dropping #{count} track(s)" if count.positive?

    drop_table :track_things_sent_emails
    drop_table :track_things
    remove_column :users, :track_things_count
  end

  def down
    add_column :users, :track_things_count, :integer, default: 0, null: false
    execute <<~SQL
      CREATE TABLE public.track_things (
          id integer NOT NULL,
          tracking_user_id integer NOT NULL,
          track_query character varying(500) NOT NULL,
          info_request_id integer,
          tracked_user_id integer,
          public_body_id integer,
          track_medium character varying NOT NULL,
          track_type character varying DEFAULT 'internal_error'::character varying NOT NULL,
          created_at timestamp without time zone,
          updated_at timestamp without time zone
      );

      CREATE TABLE public.track_things_sent_emails (
          id integer NOT NULL,
          track_thing_id integer NOT NULL,
          info_request_event_id integer,
          user_id integer,
          public_body_id integer,
          created_at timestamp without time zone,
          updated_at timestamp without time zone
      );

      CREATE SEQUENCE public.track_things_id_seq
          AS integer
          START WITH 1
          INCREMENT BY 1
          NO MINVALUE
          NO MAXVALUE
          CACHE 1;

      CREATE SEQUENCE public.track_things_sent_emails_id_seq
          AS integer
          START WITH 1
          INCREMENT BY 1
          NO MINVALUE
          NO MAXVALUE
          CACHE 1;

      ALTER SEQUENCE public.track_things_id_seq OWNED BY public.track_things.id;

      ALTER SEQUENCE public.track_things_sent_emails_id_seq OWNED BY public.track_things_sent_emails.id;

      ALTER TABLE ONLY public.track_things ALTER COLUMN id SET DEFAULT nextval('public.track_things_id_seq'::regclass);

      ALTER TABLE ONLY public.track_things_sent_emails ALTER COLUMN id SET DEFAULT nextval('public.track_things_sent_emails_id_seq'::regclass);

      ALTER TABLE ONLY public.track_things
          ADD CONSTRAINT track_things_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.track_things_sent_emails
          ADD CONSTRAINT track_things_sent_emails_pkey PRIMARY KEY (id);

      CREATE UNIQUE INDEX index_track_things_on_tracking_user_id_and_track_query ON public.track_things USING btree (tracking_user_id, track_query);

      CREATE INDEX index_track_things_sent_emails_on_created_at ON public.track_things_sent_emails USING btree (created_at);

      CREATE INDEX index_track_things_sent_emails_on_info_request_event_id ON public.track_things_sent_emails USING btree (info_request_event_id);

      CREATE INDEX index_track_things_sent_emails_on_track_thing_id ON public.track_things_sent_emails USING btree (track_thing_id);

      ALTER TABLE ONLY public.track_things
          ADD CONSTRAINT fk_track_request_info_request FOREIGN KEY (info_request_id) REFERENCES public.info_requests(id);

      ALTER TABLE ONLY public.track_things_sent_emails
          ADD CONSTRAINT fk_track_request_info_request_event FOREIGN KEY (info_request_event_id) REFERENCES public.info_request_events(id);

      ALTER TABLE ONLY public.track_things
          ADD CONSTRAINT fk_track_request_public_body FOREIGN KEY (public_body_id) REFERENCES public.public_bodies(id);

      ALTER TABLE ONLY public.track_things_sent_emails
          ADD CONSTRAINT fk_track_request_public_body FOREIGN KEY (public_body_id) REFERENCES public.public_bodies(id);

      ALTER TABLE ONLY public.track_things
          ADD CONSTRAINT fk_track_request_tracked_user FOREIGN KEY (tracked_user_id) REFERENCES public.users(id);

      ALTER TABLE ONLY public.track_things
          ADD CONSTRAINT fk_track_request_tracking_user FOREIGN KEY (tracking_user_id) REFERENCES public.users(id);

      ALTER TABLE ONLY public.track_things_sent_emails
          ADD CONSTRAINT fk_track_request_user FOREIGN KEY (user_id) REFERENCES public.users(id);
    SQL
  end
end
