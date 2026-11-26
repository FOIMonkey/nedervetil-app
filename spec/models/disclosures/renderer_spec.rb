require 'spec_helper'

RSpec.describe Disclosures::Renderer do
  describe '.html_text' do
    it 'keeps the line breaks inside pre and joins lines everywhere else' do
      html = "<p>Vans   in\n  North</p><pre>North   12\n  South  9</pre>"
      expect(described_class.html_text(html)).
        to eq("Vans in North\n\nNorth 12\nSouth 9")
    end
  end
end
