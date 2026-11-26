require 'spec_helper'

RSpec.describe AttachmentManagement::WordMap do
  def word(text, line: '0', box: [0.1, 0.2, 0.3, 0.23])
    { text: text, line: line, box: box }
  end

  describe '.of' do
    it 'gives each word its place among those kept as its id' do
      map = described_class.of([word('Visible'), word('  '),
                                word(' records ', line: '1')])
      expect(map).to eq(
        state: 'ready',
        words: [{ id: '0', text: 'Visible', line: '0',
                  box: [0.1, 0.2, 0.3, 0.23] },
                { id: '1', text: 'records', line: '1',
                  box: [0.1, 0.2, 0.3, 0.23] }]
      )
    end

    it 'keeps a box within the page and leaves out a word that is off it' do
      map = described_class.of(
        [word('Edge', box: [0.9, -0.01, 1.02, 0.05]),
         word('Off', box: [1.01, 0.2, 1.2, 0.3]),
         word('Flat', box: [0.2, 0.3, 0.2, 0.4])]
      )
      expect(map[:words]).
        to eq([{ id: '0', text: 'Edge', line: '0',
                 box: [0.9, 0.0, 1.0, 0.05] }])
    end

    it 'says a page with no words is unreadable' do
      expect(described_class.of([])).to eq(state: 'unreadable', words: [])
      expect(described_class.of([word(' ')])).
        to eq(state: 'unreadable', words: [])
    end

    it 'refuses too many words, too much text or an over-long word, giving no part of the page' do
      many = Array.new(described_class::MAX_WORDS + 1) { word('word') }
      expect(described_class.of(many)).to eq(state: 'limit', words: [])
      expect(described_class.of([word('x' * 501)])).
        to eq(state: 'limit', words: [])
      long = Array.new(201) { word('x' * 500) }
      expect(described_class.of(long)).to eq(state: 'limit', words: [])
    end
  end

  describe 'masking the kept words' do
    let(:request) { double('request') }
    let(:result) do
      described_class.of([word('Visible'), word('SECRET')])
    end

    def mask_with(pattern)
      allow(request).to receive(:apply_all_masks) { |value, *_args, **_options|
        value.gsub(pattern, '[redacted]')
      }
    end

    it 'removes masked words without exposing them or replacement text' do
      mask_with(/SECRET/)
      mapped = described_class.masked(result, request)
      expect(mapped[:state]).to eq('partial')
      expect(mapped[:words].map { |word| word[:text] }).to eq(['Visible'])
      expect(mapped.to_json).not_to include('SECRET', '[redacted]')
    end

    it 'withholds a masked multi-word line' do
      mask_with(/Visible SECRET/)
      expect(described_class.masked(result, request)).
        to eq(state: 'masked', words: [])
    end

    it 'withholds the entire map when a cross-line rule cannot be located safely' do
      result = described_class.of([word('First', line: '1'),
                                   word('Second', line: '2')])
      mask_with(/First\nSecond/)
      expect(described_class.masked(result, request)).
        to eq(state: 'masked', words: [])
    end

    it 'returns no words for missing request policy or a masking exception' do
      expect(described_class.masked(result, nil)[:words]).to be_empty
      allow(request).to receive(:apply_all_masks).
        and_raise(StandardError, 'private error detail')
      expect(described_class.masked(result, request)).
        to eq(state: 'unavailable', words: [])
    end

    it 'logs which error stopped the masking, by its class and the request’s id' do
      request = double('request', id: 5)
      allow(request).to receive(:apply_all_masks).
        and_raise(NoMethodError, 'private error detail')
      allow(Rails.logger).to receive(:warn).and_call_original
      expect(described_class.masked(result, request)).
        to eq(state: 'unavailable', words: [])
      expect(Rails.logger).to have_received(:warn).
        with('attachment_word_map_masking_failed info_request_id=5 ' \
             'NoMethodError')
    end
  end

  describe '.for_editor' do
    it 'masks the words as the request is now, with suggestions from all of them' do
      map = { state: 'ready', words: [] }
      visible = { state: 'partial', words: [] }
      personal = { state: 'ready', items: [] }
      request = instance_double(InfoRequest)
      requester = instance_double(User)
      allow(described_class).to receive(:masked).with(map, request).
        and_return(visible)
      allow(AttachmentManagement::PersonalSuggestions).to receive(:for).
        with(map, visible: visible, user: requester, name_consent: true).
        and_return(personal)
      expect(described_class.for_editor(map, request, requester: requester,
                                                      name_consent: true)).
        to eq(state: 'partial', words: [], personal: personal)
    end
  end
end
