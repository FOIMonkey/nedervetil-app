require 'ipaddr'
require 'user_spam_scorer'

path = Rails.root.join('config/user_spam_scorer.yml')

if File.exist?(path)
  settings = YAML.load(
    File.read(path),
    permitted_classes: [Regexp]
  )['user_spam_scorer']
  UserSpamScorer.configure(settings)
end
