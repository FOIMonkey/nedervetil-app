namespace :incoming_attention do
  desc 'Check again any reply whose reading failed or stalled'
  task recover: :environment do
    puts IncomingAttention::Recovery.run
  end
end
