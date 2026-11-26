require 'spec_helper'

# The rules used at sign-up, sign-in and email change (UserSpamCheck).
RSpec.describe UserSpamScorer, 'rule sets' do
  def user(name:, email:)
    FactoryBot.build(:user, name: name, email: email)
  end

  it 'scores accounts by name, email, user agent and IP' do
    rules = described_class.for_accounts
    expect(rules.spam_score_threshold).to eq(12)
    expect(rules.spam?(user(name: 'Ruth Calder',
                            email: 'ruth@example.org'))).to be(false)
    expect(rules.spam?(user(name: 'Ruth Calder',
                            email: 'ruth@allemaling.com'))).to be(true)
  end

  it 'is the only rule set, with no profile text rules' do
    expect(described_class.for_accounts.score_mappings).
      to eq(described_class::DEFAULT_SCORE_MAPPINGS)
    expect(described_class::DEFAULT_SCORE_MAPPINGS.keys.grep(/about_me/)).
      to be_empty
    expect(described_class).not_to respond_to(:for_profile_text)
  end
end
