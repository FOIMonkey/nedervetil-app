# frozen_string_literal: true

require 'office_package/error'

module OfficePackage
  ##
  # Reads the streams of a compound file (an OLE file: the old .doc, .xls
  # and .ppt, an embedded OLE object, an encrypted Office file). Written
  # from [MS-CFB].
  #
  # A stream's sectors are found by following its chain through the
  # allocation table, so text that crosses from one sector to another that
  # isn't next to it in the file is read whole. A raw scan of the file's
  # bytes would miss it.
  #
  #   file = OfficePackage::CompoundFile.new(bytes)
  #   file.streams    # => [["Root Entry/WordDocument", "..."], ...]
  #   file.encrypted? # => true for an encrypted Office file
  class CompoundFile
    FREE = 0xFFFFFFFF
    END_OF_CHAIN = 0xFFFFFFFE
    FAT_SECTOR = 0xFFFFFFFD
    DIFAT_SECTOR = 0xFFFFFFFC
    MAX_REGULAR = 0xFFFFFFFA
    NO_STREAM = 0xFFFFFFFF
    STORAGE = 1
    STREAM = 2
    ROOT = 5
    HEADER_DIFAT = 109
    ENTRY = 128
    MAX_ENTRIES = 100_000

    Entry = Struct.new(:index, :name, :type, :left, :right, :child, :start,
                       :byte_size, keyword_init: true)

    attr_reader :bytes

    def initialize(bytes)
      @bytes = bytes.b
      raise NotPackage, 'not a compound file' unless
        @bytes.start_with?(COMPOUND_FILE_MAGIC)

      header
      @fat = fat
      @entries = directory
      root = @entries.first
      refuse!('no root entry') unless root&.type == ROOT
      @mini_stream = chain_data(root.start, root.byte_size)
      @mini_fat = table(@mini_fat_start, @mini_fat_count)
    end

    # [[path, data], ...] for every stream. A file whose streams add up to
    # far more than its own size (chains shared between entries) is refused.
    def streams
      @streams ||= begin
        found = []
        budget = [bytes.bytesize * 4, MAX_TOTAL].min
        stack = [[@entries.first.child, []]]
        seen = Set.new
        until stack.empty?
          index, path = stack.pop
          next if index == NO_STREAM || index >= @entries.size

          refuse!('a directory tree that loops') unless seen.add?(index)

          entry = @entries[index]
          stack << [entry.right, path] << [entry.left, path]
          case entry.type
          when STREAM
            budget -= stream_bytes(entry)
            refuse!('streams far larger than the file') if budget.negative?
            found << [(path + [entry.name]).join('/'), stream(entry)]
          when STORAGE
            stack << [entry.child, path + [entry.name]]
          end
        end
        found
      end
    end

    def encrypted?
      names = streams.map { |path, _data| path.split('/').last }
      names.include?('EncryptionInfo') && names.include?('EncryptedPackage')
    end

    private

    def header
      if bytes.bytesize < 512
        refuse!('a compound file too short for its header')
      end
      major, order, shift, mini_shift = bytes.unpack('@26vvvv')
      refuse!('a compound file in an unknown byte order') unless order == 0xFFFE
      unless [[3, 9], [4, 12]].include?([major, shift])
        refuse!('a compound file of an unknown version')
      end
      refuse!('a compound file with odd mini sectors') unless mini_shift == 6
      @sector = 1 << shift
      @mini = 1 << mini_shift
      _dir_sectors, @fat_count, @dir_start, _transaction, @cutoff,
        @mini_fat_start, @mini_fat_count, @difat_start, @difat_count =
        bytes.unpack('@40VVVVVVVVV')
      @header_difat = bytes.unpack("@76V#{HEADER_DIFAT}")
      @sectors = ((bytes.bytesize - @sector) / @sector.to_f).ceil
    end

    def sector_data(number)
      refuse!('a sector outside the file') if number >= @sectors
      bytes.byteslice((number + 1) * @sector, @sector).ljust(@sector, "\0".b)
    end

    # The allocation table's sectors, from the header and then the DIFAT
    # chain.
    def fat
      refuse!('an allocation table of the wrong size') if @fat_count > @sectors
      locations = []
      seen_fat = Set.new
      add_fat = ->(number) do
        return if number > MAX_REGULAR

        unless seen_fat.add?(number)
          refuse!('a duplicate allocation table sector')
        end
        locations << number
      end
      @header_difat.each(&add_fat)
      next_difat = @difat_start
      seen = Set.new
      @difat_count.times do
        break if next_difat > MAX_REGULAR

        refuse!('a DIFAT chain that loops') unless seen.add?(next_difat)
        values = sector_data(next_difat).unpack('V*')
        next_difat = values.pop
        values.each(&add_fat)
      end
      refuse!('an allocation table of the wrong size') if
        locations.size < @fat_count
      locations.first(@fat_count).flat_map do |number|
        sector_data(number).unpack('V*')
      end
    end

    # A table (the mini allocation table) stored as a chain of sectors.
    def table(start, count)
      return [] if count.zero? || start > MAX_REGULAR

      chain(start, @fat, @sectors, count).flat_map do |number|
        sector_data(number).unpack('V*')
      end
    end

    def chain(start, table, limit, max = nil)
      numbers = []
      seen = Set.new
      number = start
      while number <= MAX_REGULAR
        refuse!('a chain outside its table') if number >= limit
        refuse!('a sector chain that loops') unless seen.add?(number)
        refuse!('a chain longer than its stream') if max && numbers.size >= max

        numbers << number
        number = table[number] || END_OF_CHAIN
      end
      refuse!('a chain that ends badly') unless number == END_OF_CHAIN
      numbers
    end

    def chain_data(start, size)
      return ''.b if size.zero?

      needed = (size + @sector - 1) / @sector
      refuse!('a stream shorter than it says') if needed > @sectors
      data = chain(start, @fat, @sectors, needed).map do |number|
        sector_data(number)
      end.join
      refuse!('a stream shorter than it says') if data.bytesize < size
      data.byteslice(0, size)
    end

    def mini_data(start, size)
      return ''.b if size.zero?

      count = @mini_stream.bytesize / @mini
      needed = (size + @mini - 1) / @mini
      refuse!('a stream shorter than it says') if needed > count
      data = chain(start, @mini_fat, count, needed).map do |number|
        @mini_stream.byteslice(number * @mini, @mini)
      end.join
      refuse!('a stream shorter than it says') if data.bytesize < size
      data.byteslice(0, size)
    end

    def directory
      sectors = chain(@dir_start, @fat, @sectors)
      count = sectors.size * (@sector / ENTRY)
      refuse!('too many directory entries') if count > MAX_ENTRIES
      data = sectors.map { |number| sector_data(number) }.join
      Array.new(count) do |index|
        raw = data.byteslice(index * ENTRY, ENTRY)
        length = raw.unpack1('@64v')
        name = raw.byteslice(0, [[length - 2, 0].max, 64].min).
               force_encoding('UTF-16LE').encode('UTF-8', invalid: :replace,
                                                          undef: :replace)
        type, _colour, left, right, child = raw.unpack('@66CCVVV')
        start, low, high = raw.unpack('@116VVV')
        size = @sector == 512 ? low : (high << 32) | low
        Entry.new(index: index, name: name, type: type, left: left,
                  right: right, child: child, start: start, byte_size: size)
      end
    end

    def stream(entry)
      if entry.byte_size < @cutoff
        mini_data(entry.start, entry.byte_size)
      else
        chain_data(entry.start, entry.byte_size)
      end
    end

    def stream_bytes(entry)
      return 0 unless entry.byte_size.positive?

      unit = entry.byte_size < @cutoff ? @mini : @sector
      ((entry.byte_size + unit - 1) / unit) * unit
    end

    def refuse!(why)
      raise Refused, why
    end
  end
end
