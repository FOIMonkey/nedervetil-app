require 'spec_helper'

RSpec.describe AttachmentManagement::PersonalSuggestions do
  let(:user) do
    Struct.new(:name, :email, :previous_names).
      new('Dr Alice Example', 'alice@example.test', [])
  end

  def map(text, lines: nil)
    { state: 'ready', words: text.split.map.with_index do |word, index|
      { id: index.to_s, text: word, line: (lines || [])[index] || '1',
        box: [0.1, 0.2, 0.3, 0.4] }
    end }
  end

  def suggested(text, **options)
    described_class.for(map(text), user: user, **options)
  end

  it 'uses the existing checks without changing their publication contract' do
    rules = Disclosures::Checks.rules_for(user)
    expect(rules.map(&:last).uniq).
      to match_array(%w[email name surname greeting title])
    expect(Disclosures::Checks.needles_for(user)).
      to eq(rules.map { |pattern, label, _| [pattern, label] })
    expect(Disclosures::Checks.needles_for(user).
             all? { |entry| entry.size == 2 }).to be true
  end

  it 'accounts for repeated occurrences and merges full-name/surname overlap' do
    result = suggested('Alice Example met Alice Example')
    expect(result[:items].map { |item| item[:words] }).to eq([%w[0 1], %w[3 4]])
    expect(result[:items].first[:kinds]).to contain_exactly('name', 'surname')
    expect(result).to include(state: 'ready', limited: false)
  end

  it 'finds an email as one occurrence and never serializes profile values or rule labels' do
    result = suggested('Contact alice@example.test for details')
    expect(result[:items].map { |item| item[:words] }).to eq([['1']])
    expect(result[:items].first[:kinds]).to include('email')
    expect(result.to_json).
      not_to include('alice@example.test', 'Alice', 'Example', 'requester’s')
  end

  it 'matches case, punctuation and a name across line boundaries' do
    result = described_class.for(
      map('To ALICE EXAMPLE, thanks', lines: %w[1 1 2 2]), user: user
    )
    expect(result[:items].map { |item| item[:words] }).to eq([%w[1 2]])
  end

  it 'keeps the greeting, titled surname and ambiguous surname rules, ' \
     'suggesting the name and not the greeting or title' do
    result = suggested('Dear Alice. Dr Example. Example')
    expect(result[:items].map { |item| item[:words] }).
      to eq([['1'], ['3'], ['4']])
    expect(result[:items].map { |item| item[:kinds] }).
      to include(['greeting'], ['surname'])
  end

  it 'uses whole-word and literal punctuation matching, including apostrophes' do
    user.name = "Alicia O'Example"
    result = suggested('PreOExample O’Example O’Examples Alicia O’Example')
    expect(result[:items].map { |item| item[:words] }).to eq([['1'], %w[3 4]])
    user.email = 'a+b@example.test'
    expect(suggested('aab@example.test a+b@example.test')[:items].
             last[:kinds]).to include('email')
  end

  it 'does not suggest unrelated official names or guess misspellings' do
    expect(suggested('Councillor Robert Other met Al1ce Examp1e')[:items]).
      to be_empty
  end

  it 'does not treat name consent as an instruction to omit email suggestions' do
    result = suggested('Alice Example alice@example.test', name_consent: true)
    expect(result[:name_consent]).to be true
    expect(result[:items].flat_map { |item| item[:kinds] }).
      to include('name', 'email')
  end

  it 'handles empty/short names without manufacturing a full name or surname' do
    user.name = 'Li'
    expect(suggested('Li')[:items]).to be_empty
    expect(suggested('Dear Li')[:items].map { |item| item[:words] }).
      to eq([['1']])
    user.name = ''
    expect(suggested('alice@example.test')[:items].first[:kinds]).
      to eq(['email'])
  end

  it 'limits excessive occurrences and reports the incomplete set' do
    result = suggested(Array.new(150, 'Alice Example').join(' '))
    expect(result[:items].size).to eq(100)
    expect(result[:limited]).to be true
  end

  it 'cannot join a name across a gap left by masking' do
    value = map('Alice private Example')
    value[:words].delete_at(1)
    value[:state] = 'partial'
    result = described_class.for(value, user: user)
    expect(result[:items].map { |item| item[:words] }).to eq([['2']])
    expect(result[:items].flat_map { |item| item[:kinds] }).
      not_to include('name')
  end

  it 'has no suggestions from withheld, unreadable or absent requester data' do
    %w[masked unreadable unavailable limit].each do |state|
      result = described_class.for({ state: state, words: [] }, user: user)
      expect(result).to include(state: 'unavailable', items: [])
    end
    expect(described_class.for(map('Alice Example'), user: nil)[:items]).
      to be_empty
  end

  it 'fails closed on a matching error without returning private exception details' do
    allow(Disclosures::Checks).to receive(:rules_for).
      and_raise(StandardError, 'private profile details')
    expect(suggested('Alice Example')).
      to include(state: 'unavailable', items: [])
    expect(suggested('Alice Example').to_json).not_to include('private profile')
  end

  it 'logs which error stopped the matching, by its class and the account’s id' do
    account = FactoryBot.build_stubbed(:user)
    allow(Disclosures::Checks).to receive(:rules_for).
      and_raise(NoMethodError, 'private profile details')
    allow(Rails.logger).to receive(:warn).and_call_original
    expect(described_class.for(map('Alice Example'), user: account)).
      to eq(state: 'unavailable', items: [], limited: false,
            name_consent: false)
    expect(Rails.logger).to have_received(:warn).
      with("attachment_personal_suggestions_failed user_id=#{account.id} " \
           'NoMethodError')
  end

  it 'returns generic geometry for masked personal details without any text, ids or profile value' do
    raw = map('Alice Example alice@example.test')
    visible = { state: 'partial', words: raw[:words].first(2) }
    result = described_class.for(raw, visible: visible, user: user,
                                      name_consent: true)
    hidden = result[:items].last
    expect(hidden).to include(areas: [[0.098, 0.198, 0.302, 0.402]],
                              cross_line: false)
    expect(hidden[:kinds]).to include('email')
    expect(hidden.keys).not_to include(:words, :text)
    expect(result.to_json).
      not_to include('Alice', 'Example', 'alice@example.test')
    expect(result[:name_consent]).to be true
  end

  it 'withholds all generic suggestions when the masking policy cannot be evaluated' do
    expect(described_class.for(map('Alice Example'),
                               visible: { state: 'unavailable', words: [] },
                               user: user)).
      to include(state: 'unavailable', items: [])
  end

  it 'splits generic masked geometry at line and column gaps' do
    raw = map('Alice Example', lines: %w[1 2])
    raw[:words].last[:box] = [0.7, 0.4, 0.8, 0.5]
    result = described_class.for(raw, visible: { state: 'masked', words: [] },
                                      user: user)
    expect(result[:items].first).
      to include(areas: [[0.098, 0.198, 0.302, 0.402],
                         [0.698, 0.398, 0.802, 0.502]],
                 cross_line: true)
  end
end
