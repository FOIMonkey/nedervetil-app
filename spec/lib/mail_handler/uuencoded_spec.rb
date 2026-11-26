require 'spec_helper'

RSpec.describe 'UUencoded mail blocks' do
  let(:block) { "begin 644 sample.txt\n(0V%T#0I#870`\n`\nend\n" }

  it 'finds and strips complete blocks without touching surrounding text' do
    text = "Before\n#{block}After\n"
    expect(MailHandler.uuencoded_blocks(text)).to eq([block])
    expect(MailHandler.strip_uuencoded_blocks(text)).to eq("Before\n After\n")
  end

  it 'does not repeatedly scan unfinished begin lines' do
    text = ("begin 644 unfinished.txt\n" * 1_000) + block
    expect(MailHandler.uuencoded_blocks(text)).to eq([block])
  end

  it 'ignores a block without its zero-length line' do
    text = "begin 644 sample.txt\n(0V%T#0I#870`\nend\n"
    expect(MailHandler.uuencoded_blocks(text)).to be_empty
  end

  it 'keeps a CRLF filename extension when identifying the part' do
    crlf = block.gsub("\n", "\r\n").sub('sample.txt', 'figures.xls')
    attachment = MailHandler.uudecode(crlf, 0).first
    expect(attachment[:filename]).to eq('figures.xls')
    expect(attachment[:content_type]).to eq('application/vnd.ms-excel')
  end
end
