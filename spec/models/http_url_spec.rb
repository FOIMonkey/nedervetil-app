require 'spec_helper'

RSpec.describe HttpUrl do
  describe '.parse' do
    {
      'https://www.example.org/foi?page=2' => 'https://www.example.org/foi?page=2',
      'http://example.org' => 'http://example.org',
      ' HTTPS://Example.org ' => 'HTTPS://Example.org',
      'javascript:alert(1)' => nil,
      'javascript:alert(1)//http://example.org' => nil,
      'data:text/html,<script>alert(1)</script>' => nil,
      'mailto:foi@example.org' => nil,
      '//example.org' => nil,
      '/relative/path' => nil,
      'example.org' => nil,
      'https://' => nil,
      'https://exa mple.org' => nil,
      '' => nil,
      nil => nil
    }.each do |value, expected|
      it "#{value.inspect} => #{expected.inspect}" do
        expect(described_class.parse(value)).to eq(expected)
      end
    end
  end

  describe '.with_default_scheme' do
    {
      'example.org' => 'https://example.org',
      'www.example.org/foi?x=1' => 'https://www.example.org/foi?x=1',
      'http://example.org' => 'http://example.org',
      'javascript:alert(1)' => nil,
      'javascript:alert(1)//http://example.org' => nil,
      'mailto:foi@example.org' => nil,
      'example.org:8080/foi' => 'https://example.org:8080/foi',
      'localhost:3000' => nil,
      'javascript:1' => nil,
      'JaVaScRiPt:alert(1)' => nil,
      'not a web address' => nil,
      'not-a-web-address' => nil,
      '' => nil
    }.each do |value, expected|
      it "#{value.inspect} => #{expected.inspect}" do
        expect(described_class.with_default_scheme(value)).to eq(expected)
      end
    end
  end
end
