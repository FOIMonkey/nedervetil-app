require 'spec_helper'

RSpec.describe StyleBlockHelper do
  include StyleBlockHelper

  describe '#sanitize_without_style_blocks' do
    it 'removes a style block with its contents' do
      html = '<style>body{display:none}</style><p>Text</p>'
      expect(sanitize_without_style_blocks(html)).to eq('<p>Text</p>')
    end

    it 'sanitises what is left' do
      html = '<STYLE>a{}</STYLE><p onclick="x()">Text</p><script>x()</script>'
      result = sanitize_without_style_blocks(html)
      expect(result).to include('<p>Text</p>')
      expect(result).not_to include('a{}', 'onclick', '<script>')
    end

    it 'passes its options to sanitize' do
      html = '<style>a{}</style><p><b>Text</b></p>'
      expect(sanitize_without_style_blocks(html, tags: %w[p])).
        to eq('<p>Text</p>')
    end

    it 'gives what sanitize gives when there is no style block' do
      html = '<p>Plain &amp; <b>simple</b></p><script>x()</script>'
      expect(sanitize_without_style_blocks(html)).to eq(sanitize(html))
    end

    it 'gives nil for nil, as sanitize does' do
      expect(sanitize_without_style_blocks(nil)).to be_nil
    end
  end
end
