# The authority API was removed (see doc/FORK.md), so authorities no longer
# need API keys. The down restores the column with a fresh key for each
# authority, made as the old before_save callback made them (SecureRandom, a
# cryptographically strong generator), so a source rollback still matches the
# schema.
class RemovePublicBodyApiKeys < ActiveRecord::Migration[8.1]
  def up
    remove_column :public_bodies, :api_key
  end

  def down
    add_column :public_bodies, :api_key, :string
    select_values('SELECT id FROM public_bodies').each do |id|
      execute 'UPDATE public_bodies ' \
              "SET api_key = #{quote(SecureRandom.base64(33))} " \
              "WHERE id = #{Integer(id)}"
    end
    change_column_null :public_bodies, :api_key, false
  end
end
