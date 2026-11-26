namespace :masking do
  desc 'Mask again every part whose masking hit a fault'
  task retry_faults: :environment do
    count = 0
    FoiAttachment.not_erased.where.not(masking_failed_at: nil).
      find_each do |part|
        FoiAttachment::MaskJob.perform_later(part)
        count += 1
      end
    puts "Queued #{count} #{'part'.pluralize(count)} to be masked again"
  end
end
