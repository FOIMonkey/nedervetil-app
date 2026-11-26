require 'spec_helper'

RSpec.describe Admin::TagHelper, type: :helper do
  include HasTagString

  describe '#render_tag' do
    let(:tag_without_value) do
      HasTagString::HasTagStringTag.new(
        model_type: 'PublicBody', name: 'foo'
      )
    end

    let(:tag_with_value) do
      HasTagString::HasTagStringTag.new(
        model_type: 'PublicBody', name: 'foo', value: 'bar'
      )
    end

    context 'tag with no value' do
      let(:record_tag) { tag_without_value }

      it 'renders the tag with a link' do
        expected = '<span class="label label-info tag">' \
                   '<a href="/admin/tags/foo?model_type=PublicBody">foo</a>' \
                   '</span>'
        expect(helper.render_tag(record_tag)).
          to eq(expected)
      end
    end

    context 'tag with a value' do
      let(:record_tag) { tag_with_value }

      it 'renders the tag and its value with links' do
        expected =
          '<span class="label label-info tag">' \
          '<a href="/admin/tags/foo?model_type=PublicBody">foo</a>:' \
          '<a href="/admin/tags/foo:bar?model_type=PublicBody">bar</a>' \
          '</span>'

        expect(helper.render_tag(record_tag)).
          to eq(expected)
      end
    end

    context 'tag with no value, as a string' do
      let(:record_tag) { 'foo' }

      it 'renders the tag with a link' do
        expected = '<span class="label label-info tag">' \
                   '<a href="/admin/tags/foo">foo</a>' \
                   '</span>'
        expect(helper.render_tag(record_tag)).
          to eq(expected)
      end
    end

    context 'tag with a value, as a string' do
      let(:record_tag) { 'foo:bar' }

      it 'renders the tag with a link' do
        expected = '<span class="label label-info tag">' \
                   '<a href="/admin/tags/foo">foo</a>:' \
                   '<a href="/admin/tags/foo:bar">bar</a>' \
                   '</span>'
        expect(helper.render_tag(record_tag)).
          to eq(expected)
      end
    end
  end

  describe '#render_tags' do
    it 'renders each tag, escaped, as one safe string' do
      html = helper.render_tags(%w[foo <b>])
      expect(html).to be_html_safe
      expect(html).to include('>foo</a></span><span class="label')
      expect(html).to include('&lt;b&gt;')
      expect(html).not_to include('<b>')
    end
  end
end
