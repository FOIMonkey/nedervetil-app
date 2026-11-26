require 'spec_helper'

RSpec.describe DateTimeHelper do
  include DateTimeHelper

  describe '#simple_date' do
    it 'formats a date in html by default' do
      time = Time.utc(2012, 11, 7, 21, 30, 26)
      expect(self).to receive(:simple_date_html).with(time)
      simple_date(time)
    end

    it 'formats a date in the specified format' do
      time = Time.utc(2012, 11, 7, 21, 30, 26)
      expect(self).to receive(:simple_date_text).with(time)
      simple_date(time, format: :text)
    end

    it 'raises an argument error if given an unrecognized format' do
      time = Time.utc(2012, 11, 7, 21, 30, 26)
      expect { simple_date(time, format: :unknown) }.
        to raise_error(ArgumentError)
    end
  end

  describe '#simple_date_html' do
    it 'carries the displayed London calendar date across local midnight' do
      Time.use_zone('Europe/London') do
        tag = Nokogiri::HTML.fragment(
          simple_date_html(Time.iso8601('2026-07-01T23:30:00Z'))
        ).at_css('time')
        expect(tag['datetime']).to eq('2026-07-02T00:30:00+01:00')
        expect(tag.text).to eq('July 02, 2026')
      end
    end

    it 'keeps the displayed date in the timestamp west of UTC' do
      Time.use_zone('America/Los_Angeles') do
        tag = Nokogiri::HTML.fragment(
          simple_date_html(Time.iso8601('2026-07-02T06:30:00Z'))
        ).at_css('time')
        expect(tag['datetime']).to eq('2026-07-01T23:30:00-07:00')
        expect(tag.text).to eq('July 01, 2026')
      end
    end

    it 'formats a date in a time tag' do
      Time.use_zone('London') do
        time = Time.utc(2012, 11, 7, 21, 30, 26)
        expected = '<time datetime="2012-11-07T21:30:26+00:00" ' \
                   'title="2012-11-07 21:30:26 +0000">November 07, 2012</time>'
        expect(simple_date_html(time)).to eq(expected)
      end
    end
  end

  describe '#simple_date_text' do
    it 'should respect time zones' do
      Time.use_zone('Australia/Sydney') do
        expect(simple_date_text(Time.utc(2012, 11, 7, 21, 30, 26))).
          to eq('November 08, 2012')
      end
    end

    it 'should handle Date objects' do
      expect(simple_date_text(Date.new(2012, 11, 21))).
        to eq('November 21, 2012')
    end
  end

  describe '#simple_time' do
    it 'returns 00:00:00 for a date' do
      expect(simple_time(Date.new(2012, 11, 21))).to eq('00:00:00')
    end

    it 'returns the time component of a datetime' do
      date = DateTime.new(2012, 11, 21, 10, 34, 56)
      expect(simple_time(date)).to eq('10:34:56')
    end

    it 'returns the time component of a time' do
      time = Time.utc(2000, 'jan', 1, 20, 15, 1)
      expect(simple_time(time)).to eq('20:15:01')
    end
  end
end
