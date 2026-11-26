# A request is its requester's and the admins' (requester_only), or the
# admins' alone (hidden). Nothing is public. The public prominences, normal
# and backpage, were turned into requester_only whenever a request was
# saved; this does it for the requests never saved since, and gives new
# requests requester_only from the column.
#
# The down puts the column's default back and leaves the requests as they
# are: a folded request can't be told from one that was requester_only
# already, and the code from before reads requester_only as its own.
class MakeEveryRequestRequesterOnlyOrHidden < ActiveRecord::Migration[8.1]
  def up
    execute "UPDATE info_requests SET prominence = 'requester_only' " \
            "WHERE prominence IN ('normal', 'backpage')"
    change_column_default :info_requests, :prominence,
                          from: 'normal', to: 'requester_only'
  end

  def down
    change_column_default :info_requests, :prominence,
                          from: 'requester_only', to: 'normal'
  end
end
