# Requests are private, so an authority's request counts were never shown and
# the "not_many_requests" tag they drove pointed at nothing. The counters go,
# and the tag with them; the admin area counts an authority's requests live.
class RemoveRequestCountersFromPublicBodies < ActiveRecord::Migration[8.1]
  def change
    remove_column :public_bodies, :info_requests_count, :integer,
                  default: 0, null: false
    remove_column :public_bodies, :info_requests_successful_count, :integer
    remove_column :public_bodies, :info_requests_not_held_count, :integer
    remove_column :public_bodies, :info_requests_overdue_count, :integer
    remove_column :public_bodies, :info_requests_visible_classified_count,
                  :integer
    remove_column :public_bodies, :info_requests_visible_count, :integer,
                  default: 0, null: false

    reversible do |direction|
      direction.up do
        execute <<~SQL
          DELETE FROM has_tag_string_tags
          WHERE model_type = 'PublicBody' AND name = 'not_many_requests'
        SQL
      end
    end
  end
end
