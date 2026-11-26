# Inert retained rows from pre-Devise redirect handling; never replayed or
# used for authentication at runtime.
class PostRedirect < ApplicationRecord
  belongs_to :user, optional: true, inverse_of: :post_redirects
end
