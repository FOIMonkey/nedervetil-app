# Checks locale collation support. Prefer .supports? to use the connection pool.
class DatabaseCollation
  attr_reader :connection

  def self.supports?(locale)
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      i = new(connection)
      i.supports?(locale)
    end
  end

  def initialize(connection)
    @connection = connection
  end

  # Accepts a locale name such as 'en_GB'; false for non-PostgreSQL adapters.
  def supports?(locale)
    postgresql? && supported_collations.include?(locale)
  end

  private

  def postgresql?
    adapter_name == 'PostgreSQL'
  end

  def supported_collations
    sql = <<-EOF.strip_heredoc.squish
    SELECT collname FROM pg_collation
    WHERE collencoding = '-1'
    OR collencoding = '#{ database_encoding }';
    EOF

    @supported_collations ||=
      connection.execute(sql).map { |row| row['collname'] }
  end

  def database_encoding
    sql = <<-EOF.strip_heredoc.squish
    SELECT encoding FROM pg_database
    WHERE datname = '#{ connection.current_database }';
    EOF

    @database_encoding ||= connection.execute(sql).first["encoding"]
  end

  def adapter_name
    @adapter_name ||= connection.adapter_name
  end
end
