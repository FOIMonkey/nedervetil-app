# A request is its requester's and the admins' (requester_only), or the
# admins' alone (hidden). Nothing is public. Fold any existing public
# prominences into requester_only and set the column default accordingly.
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
