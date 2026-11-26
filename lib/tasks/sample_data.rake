namespace :sample_data do
  desc 'Load invented authorities, accounts and requests into an empty ' \
       'development database'
  task load: :environment do
    SampleData.load!
    puts 'Sign in with:', SampleData.accounts
  rescue SampleData::Refused => e
    abort e.message
  end

  desc 'Show the sample accounts and their password'
  task accounts: :environment do
    puts SampleData.accounts
  end
end
