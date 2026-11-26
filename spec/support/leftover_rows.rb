# Feature gates for users can be left committed in the test database, and
# loading fixtures restarts user ids, so a new user could inherit another
# user's gates.
RSpec.configure do |config|
  config.before do
    users = User.pluck(:id).map { |id| "User;#{id}" }
    Flipper::Adapters::ActiveRecord::Gate.where(key: 'actors').
      where('value LIKE ?', 'User;%').where.not(value: users).delete_all
    # Same for the request limits' send log: fixture loads delete users without
    # the foreign key's cascade.
    RequestLimits::Send.where.not(user_id: User.select(:id)).delete_all
  end
end
