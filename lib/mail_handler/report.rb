module MailHandler
  # Builds the JSON report and part files handed from script/mail_worker.rb to
  # MailHandler::Reading (loads without Rails).
  #
  # Schema (within limits):
  #   'parts'    array of { PART_FIELDS, 'body' => {bytes, encoding} (file
  #              part-<index>), 'uuencoded' => [{ BLOCK_FIELDS, 'body' } (file
  #              uu-<index>-<block>)] or nil once MAX_UU_BLOCKS is reached }
  #   'count_first_uudecode_count'  starting number for uuencoded attachments
  #   'matched'  { 'part' => index } or { 'part', 'uuencoded' (file matched) }
  #
  # Over limits: { 'too_complex' => reason } with no files.
  # Strings are packed with their Ruby encoding (.pack) for round-tripping.
  module Report
    BLOCK_FIELDS = %i[content_type filename hexdigest].freeze
    PART_FIELDS = %i[
      url_part_number content_type filename charset within_rfc822_subject
      hexdigest
    ].freeze

    MATCHED_FILE = 'matched'.freeze

    MAX_BYTES = 16 * 1024 * 1024

    module_function

    # Builds [report_hash, { filename => bytes }]. bodies: :all, :none, or a
    # part hexdigest; stored: matches a stored file to its original part.
    def build(source, bodies: :all, stored: nil)
      mail = MailHandler.mail_from_source(source)
      parts = MailHandler.get_attachment_attributes(mail)
      files = {}
      matched = match(parts, stored, files) if stored
      wanted = wanted(parts, bodies, matched)
      blocks = 0
      report = {
        'parts' => parts.each_with_index.map do |attrs, index|
          described = part(attrs, index, files, body: wanted.include?(index))
          next described unless bodies == :all

          found = uuencoded(attrs, index, files) if blocks < MAX_UU_BLOCKS
          blocks += found.size if found
          described.merge('uuencoded' => found)
        end,
        'count_first_uudecode_count' => mail.count_first_uudecode_count
      }
      report['matched'] = matched if stored
      [report, files]
    rescue MailHandler::TooComplex => e
      [{ 'too_complex' => e.message }, {}]
    end

    # Serializes report; replaces reports over MAX_BYTES with too_complex.
    def written(report, files)
      json = JSON.generate(report)
      return [json, files] if json.bytesize <= MAX_BYTES

      reason = "its parts take more than #{MAX_BYTES} bytes to describe"
      [JSON.generate('too_complex' => reason), {}]
    end

    def wanted(parts, bodies, matched)
      indexes = case bodies
                when :all then parts.each_index.to_a
                when :none then []
                else [parts.index { |attrs| attrs[:hexdigest] == bodies }]
                end
      indexes << matched['part'] if matched && !matched['uuencoded']
      indexes.compact
    end

    def part_file(index)
      "part-#{index}"
    end

    def block_file(index, block)
      "uu-#{index}-#{block}"
    end

    # Encodes strings with their Ruby encoding for JSON round-tripping.
    def pack(value)
      return value unless value.is_a?(String)

      text = value.dup.force_encoding('UTF-8')
      if text.valid_encoding?
        { 'text' => text, 'encoding' => value.encoding.name }
      else
        { 'base64' => [value].pack('m0'), 'encoding' => value.encoding.name }
      end
    end

    # Inverse of .pack; raises ArgumentError on invalid structures.
    def unpack(packed)
      return packed unless packed.is_a?(Hash)

      bytes = case packed.keys.sort
              when %w[encoding text] then packed['text']
              when %w[base64 encoding] then packed['base64'].unpack1('m0')
              end
      raise ArgumentError, 'not a packed string' unless bytes.is_a?(String)

      bytes.dup.force_encoding(encoding(packed['encoding']))
    end

    # Validates an encoding name, rejecting dummy and non-ASCII-compatible
    # encodings (e.g. UTF-16, UTF-7) that break standard String operations.
    def encoding(name)
      raise ArgumentError, 'unknown encoding' unless
        Encoding.name_list.include?(name)

      found = Encoding.find(name)
      raise ArgumentError, 'unusable encoding' if
        found.dummy? || !found.ascii_compatible?

      found
    end

    def part(attrs, index, files, body:)
      files[part_file(index)] = attrs[:body] if body
      fields(attrs, PART_FIELDS).merge('body' => body(attrs[:body]))
    end

    # Scans a part for uuencoded blocks; any part may be chosen as main text.
    def uuencoded(attrs, index, files)
      found = MailHandler.uudecode(attrs[:body].b, 0)
      found.each_with_index.map do |block, number|
        files[block_file(index, number)] = block[:body]
        fields(block, BLOCK_FIELDS).merge('body' => body(block[:body]))
      end
    end

    def fields(attrs, names)
      names.to_h { |name| [name.to_s, pack(attrs[name])] }
    end

    def body(bytes)
      { 'bytes' => bytes.bytesize, 'encoding' => bytes.encoding.name }
    end

    # Matches a stored file against parts (raw or stripped of added headers),
    # then against uuencoded blocks in text/plain parts.
    def match(parts, stored, files)
      index = index_matching(parts, stored)
      inner = MailHandler.decoded_part_body(Mail.new(stored))
      index ||= index_matching(parts, inner) unless inner.empty?
      return { 'part' => index } if index

      hexdigest = MailHandler.calculate_hexdigest(stored)
      parts.each_with_index do |attrs, part|
        next unless attrs[:content_type] == 'text/plain'

        MailHandler.uudecode(attrs[:body], attrs[:url_part_number]).
          each do |block|
            next unless MailHandler.calculate_hexdigest(block[:body]) ==
                        hexdigest

            files[MATCHED_FILE] = block[:body]
            names = BLOCK_FIELDS + [:url_part_number]
            return { 'part' => part,
                     'uuencoded' => fields(block, names).
                                    merge('body' => body(block[:body])) }
          end
      end
      nil
    end

    def index_matching(parts, bytes)
      hexdigest = MailHandler.calculate_hexdigest(bytes)
      parts.index do |attrs|
        hexdigest == MailHandler.calculate_hexdigest(attrs[:body]) ||
          hexdigest == MailHandler.calculate_hexdigest(attrs[:original_body])
      end
    end
  end
end
