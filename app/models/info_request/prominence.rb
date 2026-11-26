class InfoRequest
  module Prominence
    # A request is its requester's and the admins' (requester_only), or
    # the admins' alone (hidden). Nothing is public.
    VALUES = %w(
      requester_only
      hidden
    ).freeze
  end
end
