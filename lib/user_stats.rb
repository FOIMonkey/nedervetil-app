# Queries user sign-up counts, dormant accounts and unbanned accounts by email
# domain for the rake tasks in lib/tasks/users.rake.
class UserStats
  # Returns a list of email domains people have used to sign up with and the
  # number of signups for each, ordered by popularity (most popular first)
  def self.list_user_domains(start_date: nil, limit: nil)
    clauses = []
    binds = []
    if start_date
      clauses << 'WHERE created_at >= ?'
      binds << start_date
    end
    sql = +"SELECT lower(substring(email, position('@' in email)+1)) " \
           'AS domain, COUNT(id) AS count FROM users '
    sql << "#{clauses.join(' ')} " if clauses.any?
    sql << 'GROUP BY domain ORDER BY count DESC'
    if limit
      sql << ' LIMIT ?'
      binds << Integer(limit)
    end
    sanitized = ActiveRecord::Base.sanitize_sql_array([sql, *binds])
    User.connection.select_all(sanitized).to_a
  end

  # Returns the number of domant users for the given domain
  # (A dormant user is one with no requests)
  def self.count_dormant_users(domain, start_date = nil)
    escaped_domain = ActiveRecord::Base.sanitize_sql_like(domain.to_s)
    scope = User.where.not(
      id: InfoRequest.where.not(user_id: nil).select(:user_id)
    ).where('email LIKE ?', "%@#{escaped_domain}")
    scope = scope.where('created_at >= ?', start_date) if start_date
    scope.count
  end

  # Returns all the Users of a given domain who have not yet been banned
  # and do not have admin privileges
  def self.unbanned_by_domain(domain, start_date = nil)
    eligible = User.
                 where("email LIKE ?", "%@#{domain}").
                   not_banned.
                     where.not(id: User.with_role(:admin).select('users.id'))

    if start_date
      eligible.where("created_at >= ?", start_date)
    else
      eligible
    end
  end
end
