require 'spec_helper'

RSpec.describe ClassificationsHelper do
  include ClassificationsHelper

  describe '#classification_radio_button' do
    subject do
      classification_radio_button(
        state, id_suffix: id_suffix, current_state: current_state
      )
    end

    let(:state) { 'successful' }
    let(:id_suffix) { nil }
    let(:current_state) { nil }

    it 'builds a radio_button for the given state' do
      html = <<-HTML.squish
      <input id="successful"
             type="radio"
             value="successful"
             name="classification[described_state]" />
      HTML

      expect(subject).to eq(html)
    end

    context 'with an id_suffix' do
      let(:id_suffix) { 3 }
      it { is_expected.to match('id="successful3"') }
    end

    context 'with a matching current_state' do
      let(:current_state) { 'successful' }
      it { is_expected.to match('checked="checked"') }
    end

    context 'with a matching current_state' do
      let(:current_state) { 'unsuccessful' }
      it { is_expected.to_not match('checked="checked"') }
    end
  end

  describe '#classification_label' do
    subject { classification_label(state, text, id_suffix: id_suffix) }

    let(:state) { 'successful' }
    let(:text) { 'All the information was sent' }
    let(:id_suffix) { nil }

    it 'builds a label for the given field' do
      expect(subject).to match_html(<<~HTML)
      <label for="successful">
        <i class="icon-standalone icon_successful"></i>
        <span>All the information was sent</span>
      </label>
      HTML
    end

    context 'with an id_suffix' do
      let(:id_suffix) { 3 }
      it { is_expected.to match('for="successful3"') }
    end
  end
end
