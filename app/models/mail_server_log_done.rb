# == Schema Information
#
# Table name: mail_server_log_dones
#
#  id         :integer          not null, primary key
#  filename   :text             not null
#  last_stat  :datetime         not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#

# Copyright (c) 2009 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

# Tracks each mail server log file imported by MailServerLog.load_file and its
# last modification timestamp so unchanged files are skipped on re-runs.
class MailServerLogDone < ApplicationRecord
  has_many :mail_server_logs,
           inverse_of: :mail_server_log_done
end
