# A reply or an outgoing message is normal or hidden. Their requester_only
# was for the same people as normal, as a request is its requester's and the
# admins' already, and nothing is made from a message as a whole, so it
# changed nothing anyone saw beyond a notice on the request page. Files keep
# requester_only (FoiAttachment.prominence_states).
#
# The down changes nothing: a folded message can't be told from one that
# was normal already, and the code from before reads normal as it read
# requester_only.
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
