# Projects (and the Dataset models only they used) were removed (see
# doc/FORK.md). This refuses to drop the tables while any of them holds a row,
# so it can never destroy data: dataset key sets and values could belong to a
# request or batch directly, not only to a project. The down recreates the
# tables as they were, so a source rollback still matches the schema.
class DropProjects < ActiveRecord::Migration[8.1]
  class ProjectsPresent < StandardError; end

  TABLES = %w[
    dataset_values dataset_value_sets dataset_keys dataset_key_sets
    project_submissions project_resources project_memberships projects
  ].freeze

  def up
    held = TABLES.filter_map do |table|
      count = select_value("SELECT COUNT(*) FROM #{table}").to_i
      "#{table} (#{count})" if count.positive?
    end
    if held.any?
      raise ProjectsPresent,
            "These tables still hold rows: #{held.join(', ')}. This " \
            'migration drops the Projects and Dataset tables only when ' \
            'all of them are empty. Export or delete those rows, then ' \
            'run the migration again.'
    end

    TABLES.each { |table| drop_table table }
    execute <<~SQL.squish
      DELETE FROM users_roles WHERE role_id IN
        (SELECT id FROM roles
         WHERE name IN ('project_owner', 'project_contributor'))
    SQL
    execute "DELETE FROM roles WHERE name IN " \
            "('project_owner', 'project_contributor')"
  end

  def down
    execute <<~SQL
      CREATE TABLE public.dataset_key_sets (
          id bigint NOT NULL,
          resource_type character varying,
          resource_id bigint,
          created_at timestamp without time zone NOT NULL,
          updated_at timestamp without time zone NOT NULL
      );

      CREATE TABLE public.dataset_keys (
          id bigint NOT NULL,
          dataset_key_set_id bigint,
          title character varying,
          format character varying,
          "order" integer,
          created_at timestamp without time zone NOT NULL,
          updated_at timestamp without time zone NOT NULL,
          options jsonb DEFAULT '{}'::jsonb
      );

      CREATE TABLE public.dataset_value_sets (
          id bigint NOT NULL,
          resource_type character varying,
          resource_id bigint,
          dataset_key_set_id bigint,
          created_at timestamp without time zone NOT NULL,
          updated_at timestamp without time zone NOT NULL
      );

      CREATE TABLE public.dataset_values (
          id bigint NOT NULL,
          dataset_value_set_id bigint,
          dataset_key_id bigint,
          value character varying,
          notes character varying,
          created_at timestamp without time zone NOT NULL,
          updated_at timestamp without time zone NOT NULL
      );

      CREATE TABLE public.project_memberships (
          id bigint NOT NULL,
          project_id bigint,
          user_id bigint,
          role_id bigint,
          created_at timestamp without time zone NOT NULL,
          updated_at timestamp without time zone NOT NULL
      );

      CREATE TABLE public.project_resources (
          id bigint NOT NULL,
          project_id bigint,
          resource_type character varying,
          resource_id bigint,
          created_at timestamp without time zone NOT NULL,
          updated_at timestamp without time zone NOT NULL
      );

      CREATE TABLE public.project_submissions (
          id bigint NOT NULL,
          project_id bigint,
          user_id bigint,
          resource_type character varying,
          resource_id bigint,
          created_at timestamp without time zone NOT NULL,
          updated_at timestamp without time zone NOT NULL,
          info_request_id bigint,
          parent_id bigint,
          current boolean DEFAULT true NOT NULL
      );

      CREATE TABLE public.projects (
          id bigint NOT NULL,
          title character varying,
          briefing text,
          created_at timestamp without time zone NOT NULL,
          updated_at timestamp without time zone NOT NULL,
          invite_token character varying,
          dataset_public boolean DEFAULT false
      );

      CREATE SEQUENCE public.dataset_key_sets_id_seq
          START WITH 1
          INCREMENT BY 1
          NO MINVALUE
          NO MAXVALUE
          CACHE 1;

      CREATE SEQUENCE public.dataset_keys_id_seq
          START WITH 1
          INCREMENT BY 1
          NO MINVALUE
          NO MAXVALUE
          CACHE 1;

      CREATE SEQUENCE public.dataset_value_sets_id_seq
          START WITH 1
          INCREMENT BY 1
          NO MINVALUE
          NO MAXVALUE
          CACHE 1;

      CREATE SEQUENCE public.dataset_values_id_seq
          START WITH 1
          INCREMENT BY 1
          NO MINVALUE
          NO MAXVALUE
          CACHE 1;

      CREATE SEQUENCE public.project_memberships_id_seq
          START WITH 1
          INCREMENT BY 1
          NO MINVALUE
          NO MAXVALUE
          CACHE 1;

      CREATE SEQUENCE public.project_resources_id_seq
          START WITH 1
          INCREMENT BY 1
          NO MINVALUE
          NO MAXVALUE
          CACHE 1;

      CREATE SEQUENCE public.project_submissions_id_seq
          START WITH 1
          INCREMENT BY 1
          NO MINVALUE
          NO MAXVALUE
          CACHE 1;

      CREATE SEQUENCE public.projects_id_seq
          START WITH 1
          INCREMENT BY 1
          NO MINVALUE
          NO MAXVALUE
          CACHE 1;

      ALTER SEQUENCE public.dataset_key_sets_id_seq OWNED BY public.dataset_key_sets.id;

      ALTER SEQUENCE public.dataset_keys_id_seq OWNED BY public.dataset_keys.id;

      ALTER SEQUENCE public.dataset_value_sets_id_seq OWNED BY public.dataset_value_sets.id;

      ALTER SEQUENCE public.dataset_values_id_seq OWNED BY public.dataset_values.id;

      ALTER SEQUENCE public.project_memberships_id_seq OWNED BY public.project_memberships.id;

      ALTER SEQUENCE public.project_resources_id_seq OWNED BY public.project_resources.id;

      ALTER SEQUENCE public.project_submissions_id_seq OWNED BY public.project_submissions.id;

      ALTER SEQUENCE public.projects_id_seq OWNED BY public.projects.id;

      ALTER TABLE ONLY public.dataset_key_sets ALTER COLUMN id SET DEFAULT nextval('public.dataset_key_sets_id_seq'::regclass);

      ALTER TABLE ONLY public.dataset_keys ALTER COLUMN id SET DEFAULT nextval('public.dataset_keys_id_seq'::regclass);

      ALTER TABLE ONLY public.dataset_value_sets ALTER COLUMN id SET DEFAULT nextval('public.dataset_value_sets_id_seq'::regclass);

      ALTER TABLE ONLY public.dataset_values ALTER COLUMN id SET DEFAULT nextval('public.dataset_values_id_seq'::regclass);

      ALTER TABLE ONLY public.project_memberships ALTER COLUMN id SET DEFAULT nextval('public.project_memberships_id_seq'::regclass);

      ALTER TABLE ONLY public.project_resources ALTER COLUMN id SET DEFAULT nextval('public.project_resources_id_seq'::regclass);

      ALTER TABLE ONLY public.project_submissions ALTER COLUMN id SET DEFAULT nextval('public.project_submissions_id_seq'::regclass);

      ALTER TABLE ONLY public.projects ALTER COLUMN id SET DEFAULT nextval('public.projects_id_seq'::regclass);

      ALTER TABLE ONLY public.dataset_key_sets
          ADD CONSTRAINT dataset_key_sets_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.dataset_keys
          ADD CONSTRAINT dataset_keys_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.dataset_value_sets
          ADD CONSTRAINT dataset_value_sets_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.dataset_values
          ADD CONSTRAINT dataset_values_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.project_memberships
          ADD CONSTRAINT project_memberships_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.project_resources
          ADD CONSTRAINT project_resources_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.project_submissions
          ADD CONSTRAINT project_submissions_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.projects
          ADD CONSTRAINT projects_pkey PRIMARY KEY (id);

      CREATE INDEX index_dataset_key_sets_on_resource_type_and_resource_id ON public.dataset_key_sets USING btree (resource_type, resource_id);

      CREATE INDEX index_dataset_keys_on_dataset_key_set_id ON public.dataset_keys USING btree (dataset_key_set_id);

      CREATE INDEX index_dataset_value_sets_on_dataset_key_set_id ON public.dataset_value_sets USING btree (dataset_key_set_id);

      CREATE INDEX index_dataset_value_sets_on_resource_type_and_resource_id ON public.dataset_value_sets USING btree (resource_type, resource_id);

      CREATE INDEX index_dataset_values_on_dataset_key_id ON public.dataset_values USING btree (dataset_key_id);

      CREATE INDEX index_dataset_values_on_dataset_value_set_id ON public.dataset_values USING btree (dataset_value_set_id);

      CREATE INDEX index_project_memberships_on_project_id ON public.project_memberships USING btree (project_id);

      CREATE INDEX index_project_memberships_on_role_id ON public.project_memberships USING btree (role_id);

      CREATE INDEX index_project_memberships_on_user_id ON public.project_memberships USING btree (user_id);

      CREATE INDEX index_project_resources_on_project_id ON public.project_resources USING btree (project_id);

      CREATE INDEX index_project_resources_on_resource_type_and_resource_id ON public.project_resources USING btree (resource_type, resource_id);

      CREATE INDEX index_project_submissions_on_current ON public.project_submissions USING btree (current);

      CREATE INDEX index_project_submissions_on_info_request_id ON public.project_submissions USING btree (info_request_id);

      CREATE INDEX index_project_submissions_on_parent_id ON public.project_submissions USING btree (parent_id);

      CREATE INDEX index_project_submissions_on_project_id ON public.project_submissions USING btree (project_id);

      CREATE INDEX index_project_submissions_on_resource_type_and_resource_id ON public.project_submissions USING btree (resource_type, resource_id);

      CREATE INDEX index_project_submissions_on_user_id ON public.project_submissions USING btree (user_id);

      ALTER TABLE ONLY public.project_memberships
          ADD CONSTRAINT fk_rails_18b611e244 FOREIGN KEY (project_id) REFERENCES public.projects(id);

      ALTER TABLE ONLY public.dataset_keys
          ADD CONSTRAINT fk_rails_1d7b4e0765 FOREIGN KEY (dataset_key_set_id) REFERENCES public.dataset_key_sets(id);

      ALTER TABLE ONLY public.project_memberships
          ADD CONSTRAINT fk_rails_21ad77d123 FOREIGN KEY (role_id) REFERENCES public.roles(id);

      ALTER TABLE ONLY public.dataset_values
          ADD CONSTRAINT fk_rails_2beeca6318 FOREIGN KEY (dataset_key_id) REFERENCES public.dataset_keys(id);

      ALTER TABLE ONLY public.dataset_values
          ADD CONSTRAINT fk_rails_32de525728 FOREIGN KEY (dataset_value_set_id) REFERENCES public.dataset_value_sets(id);

      ALTER TABLE ONLY public.dataset_value_sets
          ADD CONSTRAINT fk_rails_76a2c7d1d8 FOREIGN KEY (dataset_key_set_id) REFERENCES public.dataset_key_sets(id);

      ALTER TABLE ONLY public.project_submissions
          ADD CONSTRAINT fk_rails_82e3cc0b47 FOREIGN KEY (parent_id) REFERENCES public.project_submissions(id);

      ALTER TABLE ONLY public.project_memberships
          ADD CONSTRAINT fk_rails_86b046ec96 FOREIGN KEY (user_id) REFERENCES public.users(id);

      ALTER TABLE ONLY public.project_resources
          ADD CONSTRAINT fk_rails_93afcb2fcc FOREIGN KEY (project_id) REFERENCES public.projects(id);

      ALTER TABLE ONLY public.project_submissions
          ADD CONSTRAINT fk_rails_a21d6246af FOREIGN KEY (project_id) REFERENCES public.projects(id);

      ALTER TABLE ONLY public.project_submissions
          ADD CONSTRAINT fk_rails_fa232950b0 FOREIGN KEY (user_id) REFERENCES public.users(id);
    SQL
  end
end
