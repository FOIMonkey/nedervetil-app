require 'spec_helper'

RSpec.describe 'Values the document layer records' do
  def source
    Dir[Rails.root.join('app/{models,controllers}/disclosures/**/*.rb')].
      map { |path| File.read(path) }.join("\n")
  end

  it 'lists each kind of withdrawal it records' do
    recorded = source.scan(/withdraw!\(\s*kind: '([a-z_]+)'/).flatten |
               source.scan(/withdrawal_kind = '([a-z_]+)'/).flatten

    expect(recorded - Disclosures::Document::WITHDRAWAL_KINDS).to be_empty
  end

  it 'refuses a kind of withdrawal it doesn’t list' do
    document = Disclosures::Document.new(withdrawal_kind: 'misplaced')

    expect(document).not_to be_valid
    expect(document.errors[:withdrawal_kind]).to be_present
    expect { document.withdraw!(kind: 'misplaced', reason: 'Synthetic') }.
      to raise_error(ArgumentError, /unknown withdrawal kind misplaced/)
  end

  it 'labels each action it logs' do
    logged = source.scan(/log!\(\s*'([a-z_]+)'/).flatten |
             %w[erased erasure_pending]

    expect(logged - Disclosures::Event::LABELS.keys).to be_empty
  end
end
