# External requests (made elsewhere and published here by an authority
# through the authority API) were removed with that API, so nothing can
# create one. This refuses to drop their columns while any request has an
# external_url, so it can never destroy one. Their check constraint goes with
# them. Besides policing those columns, that constraint was what required
# every other request to have a user, so info_requests.user_id becomes NOT
# NULL in its place (the holding pen belongs to the internal admin user). The
# down restores the nullable user_id, the empty columns and the constraint,
# so a source rollback still matches the schema.
class RemoveExternalRequests < ActiveRecord::Migration[8.1]
  class ExternalRequestsPresent < StandardError; end

  def up
    count = select_value(
      'SELECT COUNT(*) FROM info_requests WHERE external_url IS NOT NULL'
    ).to_i
    if count.positive?
      raise ExternalRequestsPresent,
            "info_requests has #{count} external request(s). This " \
            'migration drops external_url and external_user_name only ' \
            'when no request has an external_url. Export or delete those ' \
            'requests, then run the migration again.'
    end

    execute 'ALTER TABLE info_requests DROP CONSTRAINT info_requests_external_ck'
    remove_column :info_requests, :external_user_name
    remove_column :info_requests, :external_url
    change_column_null :info_requests, :user_id, false
  end

  def down
    change_column_null :info_requests, :user_id, true
    add_column :info_requests, :external_user_name, :string
    add_column :info_requests, :external_url, :string
    execute <<~SQL
      ALTER TABLE info_requests ADD CONSTRAINT info_requests_external_ck
        CHECK ((((user_id IS NULL) = (external_url IS NOT NULL)) AND
                ((external_url IS NOT NULL) OR (external_user_name IS NULL))))
    SQL
  end
end
