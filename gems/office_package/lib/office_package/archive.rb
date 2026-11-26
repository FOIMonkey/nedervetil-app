# frozen_string_literal: true

require 'zlib'

module OfficePackage
  ##
  # The zip structure of a package, read from the end of central directory
  # record back to each entry's local header (APPNOTE.TXT 4.3). Entries,
  # their data descriptors, the central directory and the end records must
  # tile the file; a gap between them is a leftover, an overlap is refused.
  #
  # Refused, because a reader could take them two ways: more than one end
  # record, a local name that differs from the central one, a name listed
  # twice (OPC names ignore case), encryption, a split archive, and any
  # compression but stored and deflated.
  class Archive
    LOCAL = 0x04034b50
    CENTRAL = 0x02014b50
    END_RECORD = 0x06054b50
    ZIP64_END = 0x06064b50
    ZIP64_LOCATOR = 0x07064b50
    DESCRIPTOR = 0x08074b50
    STORED = 0
    DEFLATED = 8
    ENCRYPTED = 0x0001
    HAS_DESCRIPTOR = 0x0008
    UTF8_NAME = 0x0800
    STRONG_ENCRYPTION = 0x0040
    MAX_COMMENT = 65_535
    END_SIZE = 22
    LOCATOR_SIZE = 20
    MASK32 = 0xFFFFFFFF
    MASK16 = 0xFFFF

    # raw_name: the name's bytes as stored. offset: the local header's.
    # data_offset/end_offset: where the compressed data starts, and where the
    # entry (with any data descriptor) ends.
    Entry = Struct.new(:name, :raw_name, :compression_method, :flags,
                       :dos_time, :dos_date, :crc, :compressed_size,
                       :uncompressed_size, :offset, :data_offset,
                       :end_offset, keyword_init: true) do
      def directory?
        name.end_with?('/')
      end
    end

    # Extra fields that only describe the entry: zip64 sizes, timestamps,
    # owners, padding. Any other kind could carry anything.
    STRUCTURAL_EXTRA = [0x0001, 0x000a, 0x5455, 0x5855, 0x7855, 0x7875,
                        0xa220, 0xcafe].freeze

    # extra_bytes: every extra field; extra_data_bytes: those not in
    # STRUCTURAL_EXTRA.
    attr_reader :bytes, :entries, :leftover_bytes, :comment_bytes,
                :extra_bytes, :extra_data_bytes

    def initialize(bytes)
      @bytes = bytes.b
      @leftover_bytes = 0
      @comment_bytes = 0
      @ranges = []
      @extra_bytes = 0
      @extra_data_bytes = 0
      @limits = OfficePackage.limits
      parse
    end

    # The bytes no reader of the parts sees: gaps, comments and extra fields,
    # each range on its own, for the detector.
    def unlisted
      @ranges.map { |from, length| bytes.byteslice(from, length) }
    end

    # Extra fields count: they can carry anything, and Writer drops them.
    def leftovers?
      leftover_bytes.positive? || comment_bytes.positive? ||
        extra_bytes.positive?
    end

    def raw(entry)
      bytes.byteslice(entry.data_offset, entry.compressed_size)
    end

    # The entry's bytes, checked against its declared size and CRC.
    def data(entry)
      raw = raw(entry) # rubocop:disable Rails/OutputSafety -- this class's own raw: the entry's bytes, not the view helper
      out = if entry.compression_method == STORED
              raw
            else
              inflate(raw, entry.uncompressed_size)
            end
      refuse!('a part is larger or smaller than the archive says') unless
        out.bytesize == entry.uncompressed_size
      refuse!('a part fails its checksum') unless Zlib.crc32(out) == entry.crc
      out
    end

    private

    def parse
      eocd = end_record
      fields = bytes.unpack("@#{eocd + 4}vvvvVVv")
      disk, cd_disk, on_disk, total, cd_size, cd_offset, comment = fields
      @comment_bytes += comment
      seen!(eocd + END_SIZE, comment)
      tail_start = eocd
      if total == MASK16 || cd_size == MASK32 || cd_offset == MASK32
        disk, cd_disk, on_disk, total, cd_size, cd_offset, tail_start =
          zip64_end(eocd)
      end
      unless disk.zero? && cd_disk.zero? && on_disk == total
        refuse!('a split archive')
      end
      if total > @limits[:entries]
        refuse!("more than #{@limits[:entries]} parts")
      end

      @entries = central_directory(cd_offset, cd_size, total)
      @entries.each { |entry| local_header(entry) }
      check_names!
      check_sizes!
      tile!(cd_offset, cd_size, tail_start)
      leftover!(eocd + END_SIZE + comment,
                bytes.bytesize - (eocd + END_SIZE + comment))
    end

    # The one end record whose comment fits the file. Another signature in
    # the comment would let a reader find a different directory.
    def end_record
      size = bytes.bytesize
      refuse!('not a zip') if size < END_SIZE
      floor = [size - END_SIZE - MAX_COMMENT, 0].max
      found = []
      position = size - END_SIZE
      while position >= floor
        position = bytes.rindex("PK\x05\x06".b, position)
        break if position.nil? || position < floor

        found << position if plausible_end?(position)
        position -= 1
      end
      refuse!('no end of central directory') if found.empty?
      refuse!('more than one end of central directory') if found.size > 1
      found.first
    end

    # Its comment fits, and it points at a central directory (or says zip64,
    # which zip64_end checks), so the same bytes inside compressed data or a
    # comment don't count.
    def plausible_end?(position)
      _disk, _cd_disk, _on_disk, total, cd_size, cd_offset, comment =
        bytes.unpack("@#{position + 4}vvvvVVv")
      return false if position + END_SIZE + comment > bytes.bytesize
      return true if [total, cd_size, cd_offset].include?(MASK32) ||
                     total == MASK16

      cd_offset + cd_size <= position &&
        (total.zero? || u32(cd_offset) == CENTRAL)
    end

    def zip64_end(eocd)
      locator = eocd - LOCATOR_SIZE
      unless locator >= 0 && u32(locator) == ZIP64_LOCATOR
        refuse!('a zip64 archive without its locator')
      end
      _disk, record, disks = bytes.unpack("@#{locator + 4}VQ<V")
      refuse!('a split archive') unless disks <= 1
      unless record + 56 <= locator && u32(record) == ZIP64_END
        refuse!('a zip64 archive without its end record')
      end
      length, _made, _needed, disk, cd_disk, on_disk, total, cd_size,
        cd_offset = bytes.unpack("@#{record + 4}Q<vvVVQ<Q<Q<Q<")
      record_end = record + 12 + length
      refuse!('a zip64 end record that overlaps') if record_end > locator
      leftover!(record_end, locator - record_end)
      [disk, cd_disk, on_disk, total, cd_size, cd_offset, record]
    end

    def central_directory(offset, size, total)
      dir_end = offset + size
      refuse!('a central directory outside the file') if
        dir_end > bytes.bytesize
      position = offset
      entries = Array.new(total) do
        entry, position = central_entry(position, dir_end)
        entry
      end
      refuse!('a central directory of the wrong size') unless
        position == dir_end
      entries
    end

    def central_entry(position, dir_end)
      unless position + 46 <= dir_end && u32(position) == CENTRAL
        refuse!('a central directory entry that is not one')
      end
      _made, _needed, flags, method, time, date, crc, csize, usize,
        name_length, extra_length, comment_length, disk, _internal,
        _external, local = bytes.unpack("@#{position + 4}vvvvvvVVVvvvvvVV")
      entry_end = position + 46 + name_length + extra_length + comment_length
      if entry_end > dir_end
        refuse!('a central directory entry runs past the directory')
      end
      raw_name = bytes.byteslice(position + 46, name_length)
      extra = bytes.byteslice(position + 46 + name_length, extra_length)
      usize, csize, local, disk = zip64_sizes(extra, usize, csize, local, disk)
      refuse!('a split archive') unless disk.zero?
      @comment_bytes += comment_length
      seen!(position + 46 + name_length, extra_length + comment_length)
      extra!(extra)
      entry = Entry.new(name: decode_name(raw_name, flags), raw_name: raw_name,
                        compression_method: method, flags: flags,
                        dos_time: time, dos_date: date, crc: crc,
                        compressed_size: csize, uncompressed_size: usize,
                        offset: local)
      [entry, entry_end]
    end

    # The zip64 extended information field holds, in this order, only the
    # values whose 32-bit (or 16-bit for disk) fields are all ones
    # (APPNOTE 4.5.3).
    def zip64_sizes(extra, usize, csize, local, disk)
      field = extra_field(extra, 0x0001)
      return [usize, csize, local, disk] unless field

      pos = 0
      read64 = ->(value) do
        next value unless value == MASK32

        refuse!('a zip64 field that is too short') if pos + 8 > field.bytesize
        val = field.unpack1("@#{pos}Q<")
        pos += 8
        val
      end
      usize = read64.call(usize)
      csize = read64.call(csize)
      local = read64.call(local)
      if disk == MASK16
        refuse!('a zip64 field that is too short') if pos + 4 > field.bytesize
        disk = field.unpack1("@#{pos}V")
      end
      [usize, csize, local, disk]
    end

    def extra!(extra)
      @extra_bytes += extra.bytesize
      position = 0
      while position + 4 <= extra.bytesize
        id, length = extra.unpack("@#{position}vv")
        if position + 4 + length > extra.bytesize
          @extra_data_bytes += extra.bytesize - position
          return
        end
        @extra_data_bytes += 4 + length unless STRUCTURAL_EXTRA.include?(id)
        position += 4 + length
      end
      @extra_data_bytes += extra.bytesize - position
    end

    def extra_field(extra, id)
      position = 0
      while position + 4 <= extra.bytesize
        header, length = extra.unpack("@#{position}vv")
        return extra.byteslice(position + 4, length) if header == id

        position += 4 + length
      end
      nil
    end

    def decode_name(raw, flags)
      name = if (flags & UTF8_NAME).zero? && !raw.ascii_only?
               raw.dup.force_encoding('IBM437').encode('UTF-8')
             else
               raw.dup.force_encoding('UTF-8')
             end
      unless name.valid_encoding? && !name.include?("\0")
        refuse!('a part name that is not valid text')
      end
      name
    end

    def local_header(entry)
      position = entry.offset
      unless position + 30 <= bytes.bytesize && u32(position) == LOCAL
        refuse!('an entry whose local header is missing')
      end
      _needed, flags, method, _time, _date, _crc, _csize, _usize,
        name_length, extra_length = bytes.unpack("@#{position + 4}vvvvvVVVvv")
      header_end = position + 30 + name_length + extra_length
      refuse!('an entry that runs past the end') if header_end > bytes.bytesize
      raw_name = bytes.byteslice(position + 30, name_length)
      refuse!('an entry whose two names differ') unless
        raw_name == entry.raw_name
      if ((entry.flags | flags) & (ENCRYPTED | STRONG_ENCRYPTION)).positive?
        refuse!('an encrypted entry')
      end
      unless [STORED, DEFLATED].include?(entry.compression_method) &&
             method == entry.compression_method
        refuse!('a compression method this site cannot read')
      end
      seen!(position + 30 + name_length, extra_length)
      extra!(bytes.byteslice(position + 30 + name_length, extra_length))
      entry.data_offset = position + 30 + name_length + extra_length
      data_end = entry.data_offset + entry.compressed_size
      refuse!('an entry that runs past the end') if data_end > bytes.bytesize
      trailer = (flags & HAS_DESCRIPTOR).zero? ? 0 : descriptor(entry, data_end)
      entry.end_offset = data_end + trailer
    end

    # Signed or not, with 32- or 64-bit sizes: the one that agrees with the
    # central directory.
    def descriptor(entry, at)
      start = u32(at) == DESCRIPTOR ? at + 4 : at
      signed = start - at
      if start + 12 <= bytes.bytesize && u32(start) == entry.crc
        if u32(start + 4) == entry.compressed_size & MASK32 &&
           u32(start + 8) == entry.uncompressed_size & MASK32 &&
           entry.compressed_size <= MASK32 &&
           entry.uncompressed_size <= MASK32
          return signed + 12
        end
        if start + 20 <= bytes.bytesize &&
           bytes.unpack("@#{start + 4}Q<Q<") ==
           [entry.compressed_size, entry.uncompressed_size]
          return signed + 20
        end
      end
      refuse!('a data descriptor that disagrees with the central directory')
    end

    def check_names!
      seen = {}
      entries.each do |entry|
        key = entry.name.downcase
        refuse!('a part listed twice') if seen.key?(key)

        seen[key] = true
      end
    end

    def check_sizes!
      total = 0
      entries.each do |entry|
        total += entry.uncompressed_size
        refuse!('too large unpacked') if total > @limits[:total]
        if entry.uncompressed_size > @limits[:ratio_from] &&
           entry.uncompressed_size > entry.compressed_size * @limits[:ratio]
          refuse!("a part compressed more than #{@limits[:ratio]} to 1")
        end
      end
    end

    def tile!(cd_offset, cd_size, tail_start)
      position = 0
      entries.sort_by(&:offset).each do |entry|
        refuse!('entries that overlap') if entry.offset < position
        leftover!(position, entry.offset - position)
        position = entry.end_offset
      end
      refuse!('entries that overlap the directory') if cd_offset < position
      leftover!(position, cd_offset - position)
      position = cd_offset + cd_size
      refuse!('a directory that overlaps the end record') if
        tail_start < position
      leftover!(position, tail_start - position)
    end

    def leftover!(from, length)
      return unless length.positive?

      @leftover_bytes += length
      seen!(from, length)
    end

    def seen!(from, length)
      @ranges << [from, length] if length.positive?
    end

    def inflate(raw, size)
      inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS)
      out = +''.b
      inflater.inflate(raw) do |chunk|
        out << chunk
        refuse!('a part larger than the archive says') if out.bytesize > size
      end
      inflater.finish.then { |rest| out << rest.to_s }
      out
    rescue Zlib::Error
      refuse!('a part that does not unpack')
    ensure
      inflater&.close
    end

    def u16(position)
      bytes.unpack1("@#{position}v")
    end

    def u32(position)
      bytes.unpack1("@#{position}V")
    end

    def refuse!(why)
      raise Refused, why
    end
  end
end
