namespace :documents do
  desc 'Queue the analysis of spreadsheets that have never been read'
  task check_unread_spreadsheets: :environment do
    FoiAttachment::SpreadsheetHold.unread.find_each do |attachment|
      attachment.file_blob.analyze_later
    end
  end

  desc 'Remove expired attachment edits, previews, and regulator packs'
  task clean_up: :environment do
    AttachmentManagement::CleanupJob.perform_now
    RegulatorPack.purge_expired!
  end

  desc 'Match approved documents against the topics\' search words again; ' \
       'run after changing those words'
  task rebuild_topic_matches: :environment do
    Disclosures::TopicMatch.rebuild
  end
end
