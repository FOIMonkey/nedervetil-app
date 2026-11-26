# A reply or an outgoing message is normal or hidden. Their requester_only
# was for the same people as normal, as a request is its requester's and the
# admins' already. Files keep requester_only.
class FoldRequesterOnlyMessagesIntoNormal < ActiveRecord::Migration[8.1]
  def up
    %w[incoming_messages outgoing_messages].each do |table|
      execute "UPDATE #{table} SET prominence = 'normal' " \
              "WHERE prominence = 'requester_only'"
    end
  end

  def down
  end
end
