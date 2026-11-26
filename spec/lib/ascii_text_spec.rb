require 'spec_helper'

RSpec.describe AsciiText do
  describe '.transliterate' do
    it 'drops accents, including the Welsh ones' do
      expect(described_class.transliterate('Café Ŵyl Ŷd ẃ ẁ ỳ')).
        to eq('Cafe Wyl Yd w w y')
    end

    it 'spells out letters that have no separate accent' do
      expect(described_class.transliterate('Straße Æble Øresund Łódź')).
        to eq('Strasse AEble Oresund Lodz')
    end

    it 'keeps a dash between words as a hyphen' do
      expect(described_class.transliterate('2019–2020 — A‐B')).
        to eq('2019-2020 - A-B')
    end

    it 'folds full-width letters to plain ones' do
      expect(described_class.transliterate('ＦＯＩ')).to eq('FOI')
    end

    it 'marks symbols and non-Latin scripts it cannot spell with ?' do
      expect(described_class.transliterate('£5 Мир')).to eq('?5 ???')
    end

    it 'drops invisible characters' do
      # Zero-width space, soft hyphen, zero-width joiner, byte order mark.
      expect(described_class.transliterate("Put​lo­ck‍er﻿")).
        to eq('Putlocker')
    end

    it 'straightens curly quotes' do
      expect(described_class.transliterate('“Deadpool” ‘HD’ «free»')).
        to eq(%("Deadpool" 'HD' "free"))
    end

    context 'when a language has its own transliteration rule' do
      around do |example|
        rule = { i18n: { transliterate: { rule: { 'ß' => 'sz' } } } }
        I18n.backend.store_translations(:en, rule)
        I18n.backend.store_translations(:cy, rule)
        example.run
      ensure
        I18n.backend.reload!
      end

      it 'ignores it, so the answer never depends on the locale' do
        AlaveteliLocalization.with_locale('cy') do
          expect(described_class.transliterate('Straße')).to eq('Strasse')
        end
      end
    end

    it 'leaves Cyrillic and Greek look-alikes alone unless asked' do
      expect(described_class.transliterate('Mоviе')).to eq('M?vi?')
    end

    it 'reads Cyrillic and Greek look-alikes as Latin letters when asked' do
      # Cyrillic о, е, Р, Greek Τ, ο and the Latin hooked ƒ.
      expect(described_class.transliterate('Mоviе Рutlocker Τοp ƒree',
                                           lookalikes: true)).
        to eq('Movie Putlocker Top free')
    end

    it 'reads a look-alike by its looks, not its sound' do
      # Greek τ, η, ε, ω and Cyrillic т, п.
      expect(described_class.transliterate('Puτlocker ηεω Puтlocker пew',
                                           lookalikes: true)).
        to eq('Putlocker new Putlocker new')
    end
  end

  describe 'LOOKALIKES' do
    it 'maps single letters that survive normalisation to one ASCII letter' do
      described_class::LOOKALIKES.each do |letter, latin|
        expect(letter.unicode_normalize(:nfkd)).to eq(letter)
        expect(latin).to match(/\A[A-Za-z]\z/)
      end
    end
  end
end
