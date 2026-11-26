# frozen_string_literal: true

require 'zlib'

module OfficePackage
  ##
  # Writes a zip from Archive entries, in the order given. An entry with no
  # new data keeps its compressed bytes, CRC and sizes; one with new data is
  # compressed again the way it was stored, at a fixed level, so the same
  # input always gives the same bytes. Names and DOS times are copied. Extra
  # fields, comments and anything between entries are not: they can carry
  # data no reader sees. No data descriptors and no zip64 (ZipGuard's limits
  # keep a package far below 4 GB).
  module Writer
    VERSION = 20
    LEVEL = 6
    # The UTF-8 name flag, and the deflate option bits for a copied entry.
    KEPT_FLAGS = Archive::UTF8_NAME
    DEFLATE_OPTIONS = 0x0006

    # items: [[entry, data_or_nil], ...] from archive.
    def self.write(archive, items)
      out = +''.b
      central = +''.b
      items.each do |entry, data|
        compressed, crc, size, flags = body(archive, entry, data)
        if [compressed.bytesize, size, out.bytesize].max > Archive::MASK32
          raise Refused, 'too large to write'
        end

        offset = out.bytesize
        name = entry.raw_name
        out << [Archive::LOCAL, VERSION, flags, entry.compression_method,
                entry.dos_time, entry.dos_date, crc, compressed.bytesize, size,
                name.bytesize, 0].pack('VvvvvvVVVvv')
        out << name << compressed
        central << [Archive::CENTRAL, VERSION, VERSION, flags,
                    entry.compression_method, entry.dos_time, entry.dos_date,
                    crc, compressed.bytesize, size, name.bytesize, 0, 0, 0, 0,
                    0, offset].pack('VvvvvvvVVVvvvvvVV')
        central << name
      end
      raise Refused, 'too many parts to write' if items.size > Archive::MASK16

      directory = out.bytesize
      out << central
      out << [Archive::END_RECORD, 0, 0, items.size, items.size,
              central.bytesize, directory, 0].pack('VvvvvVVv')
    end

    def self.body(archive, entry, data)
      if data.nil?
        flags = entry.flags & KEPT_FLAGS
        flags |= entry.flags & DEFLATE_OPTIONS if
          entry.compression_method == Archive::DEFLATED
        return [archive.raw(entry), entry.crc, entry.uncompressed_size, flags]
      end

      data = data.b
      compressed = if entry.compression_method == Archive::DEFLATED
                     deflate(data)
                   else
                     data
                   end
      [compressed, Zlib.crc32(data), data.bytesize,
       entry.flags & KEPT_FLAGS]
    end

    def self.deflate(data)
      deflater = Zlib::Deflate.new(LEVEL, -Zlib::MAX_WBITS, 8,
                                   Zlib::DEFAULT_STRATEGY)
      deflater.deflate(data, Zlib::FINISH)
    ensure
      deflater&.close
    end
  end
end
