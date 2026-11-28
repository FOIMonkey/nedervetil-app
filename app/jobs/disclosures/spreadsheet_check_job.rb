module Disclosures
  # Keep for one release so Sidekiq can run checks queued under the old name.
  SpreadsheetCheckJob = FoiAttachment::SpreadsheetCheckJob
end
