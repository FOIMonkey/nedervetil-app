require_relative 'spec_helper'

RSpec.describe OfficePackage::CompoundFile do
  let(:long) { "#{'x' * 506}Jane Example#{'y' * 4000}" }
  let(:short) { "#{'a' * 60}John Sample#{'b' * 100}" }

  it 'reads every stream, from the mini stream and from sectors' do
    file = described_class.new(
      OfficeFixtures.compound({ 'Big' => long, 'Small' => short })
    )
    expect(file.streams).to contain_exactly(['Big', long], ['Small', short])
    expect(file).not_to be_encrypted
  end

  it 'follows each stream’s chain, so text across sectors out of order is read whole' do
    bytes = OfficeFixtures.compound({ 'Big' => long, 'Small' => short },
                                    scramble: true)
    expect(bytes).not_to include('Jane Example', 'John Sample')
    file = described_class.new(bytes)
    expect(file.streams.to_h).to eq('Big' => long, 'Small' => short)
  end

  it 'tells an encrypted Office file' do
    file = described_class.new(
      OfficeFixtures.compound({ 'EncryptionInfo' => 'x' * 10,
                                'EncryptedPackage' => 'y' * 5000 })
    )
    expect(file).to be_encrypted
  end

  it 'refuses a chain that loops' do
    bytes = OfficeFixtures.compound({ 'Big' => long }).b
    # The stream starts at sector 0; point sector 0 back at itself.
    fat_sector = bytes.unpack1('@76V')
    bytes[(fat_sector + 1) * 512, 4] = [0].pack('V')
    expect { described_class.new(bytes).streams }.
      to raise_error(OfficePackage::Refused, /loops/)
  end

  it 'refuses a chain longer than the stream size' do
    bytes = OfficeFixtures.compound({ 'Big' => 'x' * 5000 }).b
    dir_start = bytes.unpack1('@48V')
    # Entry 1 (Big) has its low size field at offset 120 within the entry.
    bytes[((dir_start + 1) * 512) + 128 + 120, 4] = [4096].pack('V')
    expect { described_class.new(bytes).streams }.
      to raise_error(OfficePackage::Refused, /longer than its stream/)
  end

  it 'refuses duplicate FAT sectors and inflated FAT counts' do
    bytes = OfficeFixtures.compound({ 'Small' => 'hi' }).b
    fat_sector = bytes.unpack1('@76V')

    dup_fat = bytes.dup
    dup_fat[44, 4] = [2].pack('V')
    dup_fat[80, 4] = [fat_sector].pack('V')
    expect { described_class.new(dup_fat) }.
      to raise_error(OfficePackage::Refused, /duplicate allocation table/)

    huge_fat = bytes.dup
    huge_fat[44, 4] = [999].pack('V')
    expect { described_class.new(huge_fat) }.
      to raise_error(OfficePackage::Refused, /wrong size/)
  end

  it 'budgets sector reads rather than declared bytes across shared streams' do
    bytes = OfficeFixtures.compound({ 'Small' => 'a' * 4096 }).b
    dir_start = bytes.unpack1('@48V')
    fat_sector = bytes.unpack1('@76V')
    dir_offset = (dir_start + 1) * 512
    template = bytes.byteslice(dir_offset + 128, 128)

    dir_sectors = 5
    entries_count = (dir_sectors * 4) - 1
    dir_bytes = bytes.byteslice(dir_offset, 128)
    (1..entries_count).each do |i|
      entry = template.dup
      right = i < entries_count ? i + 1 : 0xFFFFFFFF
      entry[72, 4] = [right].pack('V')
      dir_bytes << entry
    end
    bytes[dir_offset, 512] = dir_bytes.byteslice(0, 512)
    first_extra = (bytes.bytesize - 512) / 512
    bytes << dir_bytes.byteslice(512..)
    chain = [dir_start, *(first_extra...(first_extra + dir_sectors - 1))]
    fat_offset = (fat_sector + 1) * 512
    chain.each_cons(2) do |a, b|
      bytes[fat_offset + (a * 4), 4] = [b].pack('V')
    end
    bytes[fat_offset + (chain.last * 4), 4] = [0xFFFFFFFE].pack('V')

    expect { described_class.new(bytes).streams }.
      to raise_error(OfficePackage::Refused, /streams far larger/)
  end

  it 'handles embedded NUL bytes in stream names without raising ArgumentError' do
    bytes = OfficeFixtures.compound({ "Sub\x00Stream" => 'hello' })
    file = described_class.new(bytes)
    expect(file.encrypted?).to be(false)
  end

  it 'refuses a storage tree nested deeper than MAX_DEPTH' do
    bytes = OfficeFixtures.compound({ 'Leaf' => 'hello' }).b
    dir_start = bytes.unpack1('@48V')
    fat_sector = bytes.unpack1('@76V')
    dir_offset = (dir_start + 1) * 512
    root = bytes.byteslice(dir_offset, 128).dup
    root[76, 4] = [1].pack('V')

    depth = described_class::MAX_DEPTH + 2
    entries = [root]
    (1..depth).each do |i|
      entry = "\x00".b * 128
      name = "D#{i}".encode('UTF-16LE').b
      entry[0, name.bytesize] = name
      entry[64, 2] = [name.bytesize + 2].pack('v')
      entry[66] = [described_class::STORAGE].pack('C')
      entry[68, 12] = [0xFFFFFFFF, 0xFFFFFFFF,
                       i < depth ? i + 1 : 0xFFFFFFFF].pack('VVV')
      entries << entry
    end
    empty_links = [0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF].pack('VVV')
    while entries.size % 4 != 0
      free = "\x00".b * 128
      free[68, 12] = empty_links
      entries << free
    end

    dir_bytes = entries.join
    dir_sectors = dir_bytes.bytesize / 512
    bytes[dir_offset, 512] = dir_bytes.byteslice(0, 512)
    first_extra = (bytes.bytesize - 512) / 512
    bytes << dir_bytes.byteslice(512..)
    chain = [dir_start, *(first_extra...(first_extra + dir_sectors - 1))]
    fat_offset = (fat_sector + 1) * 512
    chain.each_cons(2) do |a, b|
      bytes[fat_offset + (a * 4), 4] = [b].pack('V')
    end
    bytes[fat_offset + (chain.last * 4), 4] = [0xFFFFFFFE].pack('V')

    expect { described_class.new(bytes).streams }.
      to raise_error(OfficePackage::Refused, /nested too deep/)
  end

  it 'says what is not a compound file' do
    expect { described_class.new('PK') }.
      to raise_error(OfficePackage::NotPackage)
  end

  # Its limit loads without the rest of OfficePackage, and is still the one
  # limit zips are held to.
  it 'shares the most a file may unpack to with zips' do
    expect(OfficePackage::MAX_TOTAL).to eq(200 * 1024 * 1024)
    expect(OfficePackage.limits[:total]).to equal(OfficePackage::MAX_TOTAL)
  end
end
