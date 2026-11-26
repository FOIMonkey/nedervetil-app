require 'spec_helper'

RSpec.describe AuthorityGroups::Map do
  describe '.check' do
    let(:current_codes) { %w[E07000001 E06000002 W06000003 S12000004] }

    before do
      allow(described_class).to receive(:current?) do |code|
        current_codes.include?(code)
      end
    end

    def body(name, tags)
      FactoryBot.create(:public_body, name: name, tag_string: tags)
    end

    it 'lists nothing when every authority has one current code of its own' do
      body('Alpha District Council', 'gss:E07000001')
      body('Gamma Council', 'gss:E06000002')

      check = described_class.check

      expect(check.not_on_map).to eq([])
      expect(check.old_codes).to eq([])
      expect(check.shared).to eq([])
      expect(check).not_to be_any
    end

    it 'lists authorities with no current district code, by name' do
      zebra = body('Zebra Council', 'gss:E07000099')
      aardvark = body('Aardvark Council', 'gss:W06000098 gss:S12000097')

      check = described_class.check

      expect(check.not_on_map).
        to eq([[aardvark, %w[W06000098 S12000097]],
               [zebra, %w[E07000099]]])
      expect(check.old_codes).to eq([])
      expect(check).to be_any
    end

    it 'lists the old codes of an authority that also has a current one' do
      gamma = body('Gamma Council', 'gss:E06000098 gss:E06000002')

      check = described_class.check

      expect(check.not_on_map).to eq([])
      expect(check.old_codes).to eq([[gamma, %w[E06000098]]])
      expect(check).to be_any
    end

    it 'lists current codes that more than one authority has, by code' do
      alpha = body('Alpha District Council', 'gss:E07000001')
      delta = body('Delta Council', 'gss:E07000001')
      wales = body('Welsh Council', 'gss:W06000003')
      also_wales = body('Another Welsh Council', 'gss:W06000003')
      shared_old = body('Old Council', 'gss:E07000090')
      body('Older Council', 'gss:E07000090')

      check = described_class.check

      expect(check.shared).
        to eq([['E07000001', [alpha, delta]],
               ['W06000003', [wales, also_wales]]])
      expect(check.not_on_map.map(&:first)).to include(shared_old)
      expect(check).to be_any
    end

    it 'ignores defunct authorities and codes for areas not drawn here' do
      body('Gone Council', 'gss:E07000077 defunct')
      body('Shire County Council', 'gss:E10000001')
      body('No Code Council', 'local_council')

      check = described_class.check

      expect(check.not_on_map).to eq([])
      expect(check.old_codes).to eq([])
      expect(check.shared).to eq([])
    end

    it 'keeps only the district codes of an authority with others too' do
      north = body('North Council', 'gss:E10000001 gss:N09000098')

      expect(described_class.check.not_on_map).
        to eq([[north, %w[N09000098]]])
    end
  end
end
