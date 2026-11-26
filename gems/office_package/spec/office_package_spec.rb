require_relative 'spec_helper'
require 'tmpdir'

RSpec.describe OfficePackage do
  let(:files) do
    [['[Content_Types].xml', OfficeFixtures.content_types({})],
     ['_rels/.rels', OfficeFixtures.rels([])],
     ['word/document.xml', '<doc>words</doc>']]
  end

  def archive(bytes)
    OfficePackage::Archive.new(bytes)
  end

  describe OfficePackage::Archive do
    it 'reads entries and their bytes' do
      read = archive(OfficeFixtures.zip(files))
      expect(read.entries.map(&:name)).to eq(files.map(&:first))
      expect(read.data(read.entries.last)).to eq('<doc>words</doc>')
      expect(read).not_to be_leftovers
    end

    it 'reads stored entries and entries with data descriptors' do
      bytes = OfficeFixtures.zip(
        [['a.xml', '<a/>', { method: 0 }],
         ['b.xml', '<b/>', { descriptor: true }]]
      )
      read = archive(bytes)
      data = read.entries.map { |entry| read.data(entry) }
      expect(data).to eq(['<a/>', '<b/>'])
      expect(read).not_to be_leftovers
    end

    it 'counts bytes no entry covers, and comments, as leftovers' do
      gap = archive(OfficeFixtures.zip(files, between: 'Jane Example'))
      expect(gap.leftover_bytes).to eq(12)
      prefixed = archive(OfficeFixtures.zip(files, prefix: 'XX'))
      expect(prefixed.leftover_bytes).to eq(2)
      commented = archive(OfficeFixtures.zip(files, comment: 'Jane'))
      expect(commented.comment_bytes).to eq(4)
      trailing = archive(OfficeFixtures.zip(files, trailing: 'tail'))
      expect(trailing.leftover_bytes).to eq(4)
    end

    it 'reads zip64 sizes from the extended information field' do
      bytes = OfficeFixtures.zip([['a.xml', '<a>zip64</a>']])
      directory = bytes.index("PK\x01\x02".b)
      entry_size = bytes.unpack1("@#{directory + 24}V")
      compressed = bytes.unpack1("@#{directory + 20}V")
      extra = [0x0001, 16, entry_size, compressed].pack('vvQ<Q<')
      name_length = bytes.unpack1("@#{directory + 28}v")
      patched = bytes.byteslice(0, directory) +
                bytes.byteslice(directory, 20) +
                [0xFFFFFFFF, 0xFFFFFFFF].pack('VV') +
                bytes.byteslice(directory + 28, 2) +
                [extra.bytesize].pack('v') +
                bytes.byteslice(directory + 32, 14) +
                bytes.byteslice(directory + 46, name_length) + extra
      size = patched.bytesize - directory
      patched += [0x06054b50, 0, 0, 1, 1, size, directory, 0].pack('VvvvvVVv')
      read = archive(patched)
      expect(read.data(read.entries.first)).to eq('<a>zip64</a>')
    end

    it 'reads the 4-byte zip64 disk field when disk is 0xFFFF' do
      bytes = OfficeFixtures.zip([['a.xml', '<a>zip64</a>']])
      directory = bytes.index("PK\x01\x02".b)
      name_length = bytes.unpack1("@#{directory + 28}v")
      prefix = bytes.byteslice(0, directory)
      head = bytes.byteslice(directory, 28)
      patch_disk = ->(extra) do
        central = head + [name_length, extra.bytesize, 0, 0xFFFF].pack('vvvv') +
                  bytes.byteslice(directory + 36, 10) +
                  bytes.byteslice(directory + 46, name_length) + extra
        out = prefix + central
        out + [0x06054b50, 0, 0, 1, 1, central.bytesize, directory, 0].
              pack('VvvvvVVv')
      end

      zero_disk = patch_disk.call([0x0001, 4, 0].pack('vvV'))
      expect(archive(zero_disk).entries.first.name).to eq('a.xml')

      split_disk = patch_disk.call([0x0001, 4, 1].pack('vvV'))
      expect { archive(split_disk) }.
        to raise_error(OfficePackage::Refused, /split archive/)

      short_disk = patch_disk.call([0x0001, 0].pack('vv'))
      expect { archive(short_disk) }.
        to raise_error(OfficePackage::Refused, /too short/)
    end

    {
      'a second end record in the comment' => ->(files) do
        once = OfficeFixtures.zip(files)
        record = once.byteslice(once.rindex("PK\x05\x06".b), 22)
        OfficeFixtures.zip(files, comment: record)
      end,
      'an encrypted entry' => ->(files) do
        OfficeFixtures.zip(files.take(2) + [['word/document.xml', 'x',
                                             { flags: 1 }]])
      end,
      'two names that differ only in case' => ->(files) do
        OfficeFixtures.zip(files + [['WORD/Document.xml', '<other/>']])
      end,
      'a local name that differs from the central one' => ->(files) do
        OfficeFixtures.zip(files.take(2) +
                           [['word/document.xml', 'x',
                             { local_name: 'word/other.xml' }]])
      end,
      'an unknown compression method' => ->(files) do
        bytes = OfficeFixtures.zip(files, comment: '')
        bytes.gsub("\x08\x00\x00\x60".b, "\x0C\x00\x00\x60".b)
      end
    }.each do |what, build|
      it "refuses #{what}" do
        expect { archive(build.call(files)) }.
          to raise_error(OfficePackage::Refused)
      end
    end

    it 'refuses an entry that points into another' do
      bytes = OfficeFixtures.zip(files)
      directory = bytes.index("PK\x01\x02".b)
      second = bytes.index("PK\x01\x02".b, directory + 1)
      # Point the second entry at the first entry's local header.
      bytes[second + 42, 4] = [0].pack('V')
      expect { archive(bytes) }.to raise_error(OfficePackage::Refused)
    end

    it 'refuses a part that unpacks to more than it says' do
      bytes = OfficeFixtures.zip(files)
      read = archive(bytes)
      entry = read.entries.last
      entry.uncompressed_size = 3
      expect { read.data(entry) }.to raise_error(OfficePackage::Refused)
    end
  end

  describe OfficePackage::Package do
    it 'says what is not a package' do
      expect { OfficePackage.read("\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1rest".b) }.
        to raise_error(OfficePackage::NotPackage, /compound file/)
      expect { OfficePackage.read('%PDF-1.7') }.
        to raise_error(OfficePackage::NotPackage)
    end

    it 'refuses a part that declares a DOCTYPE, including in UTF-16' do
      xml = '<!DOCTYPE d [<!ENTITY e "x">]><d>&e;</d>'
      expect(Nokogiri).not_to receive(:XML)
      [xml,
       "\xFF\xFE".b + xml.encode('UTF-16LE').b,
       "\xFE\xFF".b + xml.encode('UTF-16BE').b].each do |encoded|
        bytes = OfficeFixtures.zip(
          files.take(2) + [['word/document.xml', encoded]]
        )
        expect { OfficePackage.read(bytes).xml('word/document.xml') }.
          to raise_error(OfficePackage::Refused, /DOCTYPE/)
      end
    end

    it 'gives back the same bytes when nothing changed' do
      bytes = OfficeFixtures.zip(files)
      expect(OfficePackage.read(bytes).to_bytes).to equal(bytes.b).or eq(bytes)
    end

    it 'removes a part with the relationships that point at it, its own ' \
       'relationships, its override and the references to it' do
      bytes = OfficeFixtures.workbook(
        workbook_rels: [['rIdP', "#{OfficeFixtures::R}pivotCacheDefinition",
                         'pivotCache/pivotCacheDefinition1.xml']],
        workbook_extra: '<pivotCaches><pivotCache cacheId="1" r:id="rIdP"/>' \
                        '</pivotCaches>',
        parts: {
          'xl/pivotCache/pivotCacheDefinition1.xml' =>
            ["#{OfficeFixtures::CT}spreadsheetml.pivotCacheDefinition+xml",
             '<pivotCacheDefinition/>'],
          'xl/pivotCache/_rels/pivotCacheDefinition1.xml.rels' =>
            [nil, OfficeFixtures.rels([])]
        }
      )
      package = OfficePackage.read(bytes)
      package.remove('xl/pivotCache/pivotCacheDefinition1.xml')
      out = OfficeFixtures.parts(package.to_bytes)
      expect(out.keys).not_to include(
        'xl/pivotCache/pivotCacheDefinition1.xml',
        'xl/pivotCache/_rels/pivotCacheDefinition1.xml.rels'
      )
      expect(out['xl/_rels/workbook.xml.rels']).not_to include('rIdP')
      expect(out['[Content_Types].xml']).not_to include('pivotCache')
      expect(out['xl/workbook.xml']).not_to include('pivotCache')
      expect(out['xl/workbook.xml']).to include('<sheets>')
    end

    it 'copies untouched entries without compressing them again, and ' \
       'writes the same bytes every time' do
      bytes = OfficeFixtures.zip(files, between: 'gap')
      first = OfficePackage.read(bytes)
      first.write('word/document.xml', '<doc>new</doc>')
      out = first.to_bytes
      second = OfficePackage.read(bytes)
      second.write('word/document.xml', '<doc>new</doc>')
      expect(second.to_bytes).to eq(out)

      before = archive(bytes)
      after = archive(out)
      expect(after).not_to be_leftovers
      expect(after.raw(after.entries.first)).
        to eq(before.raw(before.entries.first))
      expect(after.data(after.entries.last)).to eq('<doc>new</doc>')
      expect(after.entries.map(&:dos_time)).
        to eq(before.entries.map(&:dos_time))
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'out.docx')
        File.binwrite(path, out)
        checked = OfficePackage::Guard.check!(path, unpack: true)
        expect(checked).to be(true)
      end
    end

    it 'finds parts no relationship reaches' do
      bytes = OfficeFixtures.word('<w:p/>', parts: {
                                    'word/leftover.xml' => [nil, '<old/>']
                                  })
      expect(OfficePackage.read(bytes).unreachable_parts).
        to eq(['word/leftover.xml'])
    end

    it 'refuses truncated central directory entries and NUL bytes in part names' do
      truncated = OfficeFixtures.zip([['a.txt', 'hello']]).b
      cd = truncated.index("PK\x01\x02".b)
      truncated[cd + 28, 6] = [50_000, 50_000, 50_000].pack('vvv')
      expect { archive(truncated) }.
        to raise_error(OfficePackage::Refused, /past the directory/)

      with_nul = OfficeFixtures.zip([["word/a\x00b.xml", '<a/>']])
      expect { archive(with_nul) }.
        to raise_error(OfficePackage::Refused, /not valid text/)
    end

    it 'tells the kind of package from its main part' do
      expect(OfficePackage.read(OfficeFixtures.word('<w:p/>')).kind).
        to eq(:document)
      expect(OfficePackage.read(OfficeFixtures.workbook).kind).
        to eq(:spreadsheet)
      expect(OfficePackage.read(
        OfficeFixtures.deck(slides: { 'ppt/slides/slide1.xml' => '<p:sld/>' })
      ).kind).to eq(:presentation)
    end
  end
end
