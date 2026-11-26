# Keep database.yml's connection pool at least as large as RAILS_MAX_THREADS.
threads_count = ENV.fetch("RAILS_MAX_THREADS", 3)
threads threads_count, threads_count

port ENV.fetch("PORT", 3000)

# Supports bin/rails restart.
plugin :tmp_restart

pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
