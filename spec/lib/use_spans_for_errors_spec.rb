require 'spec_helper'

RSpec.describe 'Field error markup' do
  it 'wraps the field in a span without escaping it' do
    field = ActionController::Base.helpers.text_field_tag(:name, "a & b")
    html = ActionView::Base.field_error_proc.call(field, nil)
    expect(html).to eq(%(<span class="fieldWithErrors">#{field}</span>))
    expect(html).to be_html_safe
  end
end
