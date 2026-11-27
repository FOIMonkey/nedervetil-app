require 'spec_helper'

RSpec.describe MaskSet do
  let(:info_request) { FactoryBot.create(:info_request) }
  let!(:black_rule) do
    FactoryBot.create(:censor_rule, censorable: info_request,
                                    text: 'Hobnob', replacement: '[black]')
  end
  let!(:blue_rule) do
    FactoryBot.create(:censor_rule, :blue, censorable: info_request,
                                           text: 'Garibaldi',
                                           replacement: '[blue]')
  end
  let(:text) do
    "Black: Hobnob. Blue: Garibaldi. Orange: biscuit@example.org " \
      "Mobile: 07700 900123 #{info_request.incoming_email}."
  end

  describe '.none' do
    it 'is empty and returns text unchanged without calling the masker' do
      set = described_class.none
      expect(set).to be_none
      expect(set.colours).to eq([])
      expect(AlaveteliTextMasker).not_to receive(:apply_masks)
      expect(set.apply(text, 'text/plain')).to eq(text)
    end
  end

  describe 'InfoRequest#masks_for' do
    it 'applies no masks for admins' do
      set = info_request.masks_for(:admins)
      expect(set).to be_none
      expect(set.apply(text, 'text/plain')).to eq(text)
    end

    it 'applies only black rules for requester and pack views' do
      %i[requester pack].each do |view|
        set = info_request.masks_for(view)
        expect(set.colours).to eq(['black'])
        result = set.apply(text, 'text/plain')
        expect(result).to include('[black]')
        expect(result).not_to include('Hobnob')
        expect(result).to include('Garibaldi')
        expect(result).to include('biscuit@example.org')
        expect(result).to include('07700 900123')
      end
    end

    it 'applies black, blue, and orange masks for public and ai views' do
      %i[public ai].each do |view|
        set = info_request.masks_for(view)
        expect(set.colours).to eq(%w[black blue orange])
        result = set.apply(text, 'text/plain')
        expect(result).to include('[black]')
        expect(result).to include('[blue]')
        expect(result).not_to include('Hobnob')
        expect(result).not_to include('Garibaldi')
        expect(result).not_to include('biscuit@example.org')
        expect(result).not_to include('07700 900123')
        expect(result).not_to include(info_request.incoming_email)
      end
    end

    it 'raises on unknown views' do
      expect { info_request.masks_for(:unknown) }.to raise_error(ArgumentError)
    end
  end

  describe 'Disclosures::Masking.masks_for' do
    let(:document) do
      Disclosures::Document.new(info_request: nil,
                                public_body: info_request.public_body,
                                owner: info_request.user)
    end
    let!(:body_black) do
      FactoryBot.create(:censor_rule, censorable: info_request.public_body,
                                      text: 'Secret', replacement: '[black]')
    end
    let!(:body_blue) do
      FactoryBot.create(:censor_rule, :blue,
                        censorable: info_request.public_body,
                        text: 'Private', replacement: '[blue]')
    end

    it 'applies matching colours for detached documents' do
      sample = 'Secret Private test@example.org'
      expect(Disclosures::Masking.masks_for(document, :admins).
               apply(sample, 'text/plain')).to eq(sample)
      expect(Disclosures::Masking.masks_for(document, :requester).
               apply(sample, 'text/plain')).
        to eq('[black] Private test@example.org')
      expect(Disclosures::Masking.masks_for(document, :pack).
               apply(sample, 'text/plain')).
        to eq('[black] Private test@example.org')
      public_text = Disclosures::Masking.masks_for(document, :public).
        apply(sample, 'text/plain')
      expect(public_text).to include('[black]')
      expect(public_text).to include('[blue]')
      expect(public_text).not_to include('test@example.org')
    end
  end

  describe 'HTML letter entity decoding in TextPass' do
    let(:rule) do
      FactoryBot.create(:censor_rule, censorable: info_request,
                                      text: 'Müller', replacement: '[name]')
    end

    it 'matches named, decimal, and hex letter entities while keeping markup entities' do
      html = '<p>M&uuml;ller, M&#252;ller, M&#xFC;ller ' \
             '&lt;tag&gt; &amp; &nbsp;</p>'
      masked = described_class.new(
        censor_rules: [rule], masks: [], default_masks: false
      ).apply(html, 'text/html')
      expect(masked).
        to eq('<p>[name], [name], [name] &lt;tag&gt; &amp;  </p>')
    end

    it 'leaves HTML entity references unchanged when no rule matches' do
      html = '<p>Caf&eacute; &amp; cr&egrave;me</p>'
      matched = []
      masked = described_class.new(
        censor_rules: [rule], masks: [], default_masks: false
      ).apply(html, 'text/html', matched: matched)
      expect(masked).to eq(html)
      expect(matched).to be_empty
    end
  end
end
