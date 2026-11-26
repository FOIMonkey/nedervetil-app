# Stripe billing and Pro pricing were removed (see doc/FORK.md). The Stripe
# customer ids on Pro accounts and the log of Stripe webhook events are copies
# of what Stripe itself keeps, not anyone's content here, so they go whatever
# they hold; the counts are reported. The down recreates the column and the
# table as they were (empty), so a source rollback still matches the schema.
class RemoveProPricing < ActiveRecord::Migration[8.1]
  def up
    customers = select_value(
      'SELECT COUNT(*) FROM pro_accounts WHERE stripe_customer_id IS NOT NULL'
    ).to_i
    say "Dropping #{customers} Stripe customer id(s)" if customers.positive?

    webhooks = select_value('SELECT COUNT(*) FROM webhooks').to_i
    say "Dropping #{webhooks} Stripe webhook event(s)" if webhooks.positive?

    remove_column :pro_accounts, :stripe_customer_id
    drop_table :webhooks
  end

  def down
    add_column :pro_accounts, :stripe_customer_id, :string
    execute <<~SQL
      CREATE TABLE public.webhooks (
          id integer NOT NULL,
          params jsonb,
          notified_at timestamp without time zone,
          created_at timestamp without time zone NOT NULL,
          updated_at timestamp without time zone NOT NULL
      );

      CREATE SEQUENCE public.webhooks_id_seq
          AS integer
          START WITH 1
          INCREMENT BY 1
          NO MINVALUE
          NO MAXVALUE
          CACHE 1;

      ALTER SEQUENCE public.webhooks_id_seq OWNED BY public.webhooks.id;

      ALTER TABLE ONLY public.webhooks ALTER COLUMN id SET DEFAULT nextval('public.webhooks_id_seq'::regclass);

      ALTER TABLE ONLY public.webhooks
          ADD CONSTRAINT webhooks_pkey PRIMARY KEY (id);
    SQL
  end
end
