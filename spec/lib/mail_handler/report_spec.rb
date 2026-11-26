require 'spec_helper'

# What the mail worker hands over (MailHandler::Report), where it is the
# report's own doing and not the walk's: how far a mail is searched for
# uuencoded blocks, and how large a report may be.
RSpec.describe MailHandler::Report do
  include UuencodedMail

  let(:limit) { MailHandler::MAX_UU_BLOCKS }

  def blocks_found(raw)
    report, files = described_class.build(raw)
    [report['parts'].map { |part| part['uuencoded']&.size },
     files.keys.grep(/\Auu-/).size]
  end

  describe '.build' do
    it 'searches every part of a mail with fewer blocks than the limit' do
      raw = uuencoded_mail(['text/plain', 2], ['text/csv', 3],
                           ['text/x-log', 0])
      expect(blocks_found(raw)).to eq([[2, 3, 0], 5])
    end

    it 'stops searching once the mail holds as many blocks as a parse ' \
       'could use, and leaves no file for what it did not search' do
      raw = uuencoded_mail(['text/csv', limit - 1], ['text/x-log', 4],
                           ['text/plain', 2], ['text/x-other', 1])
      expect(blocks_found(raw)).to eq([[limit - 1, 4, nil, nil], limit + 3])
    end

    it 'takes no more from one part than a parse would' do
      raw = uuencoded_mail(['text/plain', limit + 5], ['text/csv', 1])
      expect(blocks_found(raw)).to eq([[limit, nil], limit])
    end

    it 'searches nothing when no part’s blocks are asked for' do
      raw = uuencoded_mail(['text/plain', 2])
      report, files = described_class.build(raw, bodies: :none)
      expect(report['parts'].map { |part| part.key?('uuencoded') }).
        to eq([false])
      expect(files).to be_empty
    end
  end

  describe '.written' do
    let(:built) { described_class.build(uuencoded_mail(['text/plain', 1])) }

    it 'is the report as JSON, with its files' do
      json, files = described_class.written(*built)
      expect(JSON.parse(json)).to eq(JSON.parse(JSON.generate(built.first)))
      expect(files).to eq(built.last)
    end

    it 'says the mail is past the limits, and leaves no files, when the ' \
       'report would be larger than a report may be' do
      stub_const("#{described_class}::MAX_BYTES", 200)

      json, files = described_class.written(*built)

      expect(JSON.parse(json)).to eq(
        'too_complex' => 'its parts take more than 200 bytes to describe'
      )
      expect(files).to be_empty
    end
  end
end
