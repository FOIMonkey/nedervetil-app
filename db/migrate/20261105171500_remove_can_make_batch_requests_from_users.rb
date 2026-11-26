# Batches are for trusted accounts (User#trusted?), so the separate "Can make
# batch requests" tick goes. An account that had the tick but isn't trusted
# can no longer make batches.
class RemoveCanMakeBatchRequestsFromUsers < ActiveRecord::Migration[8.1]
  def change
    remove_column :users, :can_make_batch_requests, :boolean,
                  default: false, null: false
  end
end
