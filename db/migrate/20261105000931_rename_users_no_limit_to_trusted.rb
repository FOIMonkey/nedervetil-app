# The "No rate limit" tick becomes "Trusted": the same flag with the same
# meaning (no sending limits), under the name the app uses for it. See
# User#trusted?.
class RenameUsersNoLimitToTrusted < ActiveRecord::Migration[8.1]
  def change
    rename_column :users, :no_limit, :trusted
  end
end
