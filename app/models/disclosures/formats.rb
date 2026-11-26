module Disclosures
  # From the declared type and extension, as core does; given bytes, they must
  # match (a .doc renamed .docx is "other"). Legacy OLE2 Office files (.doc and
  # .xls) require the OLE2 compound header; OOXML files require their XML main
  # part. An archive of too many parts raises ZipGuard::Refused.
  module Formats
    OLE2 = "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1".b.freeze
    PDF = %w[application/pdf].freeze
    SPREADSHEET = {
      '.xlsx' => 'application/vnd.openxmlformats-officedocument.' \
                 'spreadsheetml.sheet',
      '.xlsm' => 'application/vnd.ms-excel.sheet.macroEnabled.12'
    }.freeze
    DOCUMENT = {
      '.docx' => 'application/vnd.openxmlformats-officedocument.' \
                 'wordprocessingml.document'
    }.freeze
    LEGACY_SPREADSHEET = {
      '.xls' => %w[application/vnd.ms-excel application/x-ms-excel]
    }.freeze
    LEGACY_DOCUMENT = {
      '.doc' => %w[application/vnd.ms-word application/msword
                   application/x-ms-word]
    }.freeze
    PRESENTATION = {
      '.pptx' => 'application/vnd.openxmlformats-officedocument.' \
                 'presentationml.presentation'
    }.freeze
    TEXT = %w[text/plain text/html].freeze
    IMAGE = AttachmentManagement::Engines::Raster::IMAGE_CODERS.keys.freeze
    IMAGE_EXTENSIONS = %w[.jpg .jpeg .png .gif .bmp .webp .tif .tiff].freeze
    OOXML = %w[.xlsx .xlsm .docx .pptx].freeze
    MAIN_PART = { 'spreadsheet' => 'xl/workbook.xml',
                  'document' => 'word/document.xml',
                  'presentation' => 'ppt/presentation.xml' }.freeze
    SUPPORTED = %w[pdf spreadsheet csv document presentation text].freeze
    REFUSED = N_('This kind of file can’t become a document; it stays in ' \
                 'the thread.').freeze
    SAFE_EXTENSION = /\A\.[a-z0-9]{1,8}\z/
    EXTENSION_ALIASES = { '.jpeg' => '.jpg',
                          '.htm' => '.html',
                          '.tif' => '.tiff' }.freeze
    TYPE_ALIASES = { 'application/msword' => 'application/vnd.ms-word',
                     'application/x-ms-word' => 'application/vnd.ms-word',
                     'application/x-ms-excel' => 'application/vnd.ms-excel',
                     'image/jpg' => 'image/jpeg',
                     'text/rtf' => 'application/rtf' }.freeze

    module_function

    def for(content_type, filename, bytes = nil)
      kind = declared(content_type, filename)
      if bytes.nil? || kind == 'other' ||
         bytes_match?(kind, bytes, content_type: content_type,
                                   filename: filename)
        kind
      else
        'other'
      end
    end

    def declared(content_type, filename)
      type = normalized_type(content_type)
      ext = extension(filename)
      return 'pdf' if PDF.include?(type) || ext == '.pdf'
      return 'csv' if type == 'text/csv' || ext == '.csv'
      return 'spreadsheet' if spreadsheet_declared?(type, ext)
      return 'document' if document_declared?(type, ext)
      return 'presentation' if presentation_declared?(type, ext)
      return 'text' if text_declared?(type, ext)
      return 'image' if image_declared?(type, ext)

      'other'
    end

    def supported?(content_type, filename, bytes = nil)
      SUPPORTED.include?(self.for(content_type, filename, bytes))
    end

    def ole2?(bytes)
      bytes.to_s.byteslice(0, OLE2.bytesize)&.b == OLE2
    end

    def legacy_doc?(content_type, filename)
      return false unless declared(content_type, filename) == 'document'

      ext = extension(filename)
      return true if LEGACY_DOCUMENT.key?(ext)
      return false if DOCUMENT.key?(ext)

      LEGACY_DOCUMENT['.doc'].include?(normalized_type(content_type))
    end

    def legacy_xls?(content_type, filename)
      return false unless declared(content_type, filename) == 'spreadsheet'

      ext = extension(filename)
      return true if LEGACY_SPREADSHEET.key?(ext)
      return false if SPREADSHEET.key?(ext)

      LEGACY_SPREADSHEET['.xls'].include?(normalized_type(content_type))
    end

    def legacy_office?(content_type, filename)
      legacy_doc?(content_type, filename) || legacy_xls?(content_type, filename)
    end

    def bytes_match?(kind, bytes, content_type: nil, filename: nil)
      case kind
      when 'pdf'
        bytes.byteslice(0, 1024).b.
          match?(/\A(?:\xEF\xBB\xBF)?[\t\n\f\r \0]*%PDF-/n)
      when 'spreadsheet', 'document'
        if legacy_office?(content_type, filename)
          ole2?(bytes)
        else
          ooxml_part?(bytes, MAIN_PART.fetch(kind))
        end
      when 'presentation'
        ooxml_part?(bytes, MAIN_PART.fetch(kind))
      when 'image'
        Marcel::MimeType.for(StringIO.new(bytes)).to_s.start_with?('image/')
      else
        text?(bytes)
      end
    end

    def ooxml_part?(bytes, part)
      return false unless OfficePackage.package?(bytes)

      ZipGuard.count!(StringIO.new(bytes))
      OfficePackage.read(bytes).include?(part)
    rescue OfficePackage::Error
      false
    end

    # Windows-1252 leaves five bytes undefined; encode raises on them.
    def text?(bytes)
      return false if bytes.b.include?("\0")
      return true if bytes.dup.force_encoding('UTF-8').valid_encoding?

      bytes.dup.force_encoding('Windows-1252').encode('UTF-8')
      true
    rescue EncodingError
      false
    end

    def html?(content_type, filename)
      content_type.to_s.downcase.include?('html') ||
        %w[.htm .html].include?(extension(filename))
    end

    def normalized_type(content_type)
      content_type.to_s.downcase.split(';').first.to_s.strip
    end

    def extension(filename)
      File.extname(filename.to_s).downcase
    end

    def extension_for(content_type, fallback_name = nil)
      type = normalized_type(content_type)
      ext = AlaveteliFileTypes.mimetype_to_extension(
        TYPE_ALIASES.fetch(type, type)
      )
      ext = ext ? ".#{ext}" : extension(fallback_name)
      ext.presence || '.bin'
    end

    def file_extension(filename, content_type)
      extension(filename).presence || extension_for(content_type)
    end

    # LibreOffice picks its import filter by extension, and the name is the
    # authority's.
    def safe_extension(filename, content_type)
      ext = extension(filename)
      ext.match?(SAFE_EXTENSION) ? ext : extension_for(content_type)
    end

    def ooxml?(filename)
      OOXML.include?(extension(filename))
    end

    def same_format?(from_ext, from_type, to_ext, to_type)
      a_ext = canonical_extension(from_ext)
      b_ext = canonical_extension(to_ext)
      return a_ext == b_ext if a_ext.present? && b_ext.present?

      canonical_type(from_type) == canonical_type(to_type)
    end

    def record_conversion(metadata, from_content_type:, from_filename:,
                          to_content_type:, to_filename:)
      notes = metadata.dup
      if notes['converted_from_extension'].present? ||
         notes['converted_from_content_type'].present?
        return notes
      end

      from_type = normalized_type(from_content_type)
      from_ext = file_extension(from_filename, from_content_type)
      to_type = normalized_type(to_content_type)
      to_ext = file_extension(to_filename, to_content_type)
      return notes if same_format?(from_ext, from_type, to_ext, to_type)

      notes['converted_from_content_type'] = from_type if from_type.present?
      if from_ext.match?(SAFE_EXTENSION) && from_ext != '.bin'
        notes['converted_from_extension'] = from_ext
      end
      notes
    end

    def spreadsheet_declared?(type, ext)
      SPREADSHEET.key?(ext) ||
        SPREADSHEET.values.any? { |value| value.casecmp?(type) } ||
        LEGACY_SPREADSHEET.key?(ext) ||
        LEGACY_SPREADSHEET['.xls'].include?(type)
    end

    def document_declared?(type, ext)
      DOCUMENT.key?(ext) ||
        DOCUMENT.values.any? { |value| value.casecmp?(type) } ||
        LEGACY_DOCUMENT.key?(ext) ||
        LEGACY_DOCUMENT['.doc'].include?(type)
    end

    def presentation_declared?(type, ext)
      PRESENTATION.key?(ext) || PRESENTATION.value?(type)
    end

    def text_declared?(type, ext)
      TEXT.include?(type) || %w[.txt .htm .html].include?(ext)
    end

    def image_declared?(type, ext)
      IMAGE.include?(type) || IMAGE_EXTENSIONS.include?(ext)
    end

    def canonical_extension(ext)
      value = ext.to_s.downcase.strip
      return nil if value.blank? || value == '.bin'

      value = ".#{value}" unless value.start_with?('.')
      EXTENSION_ALIASES.fetch(value, value)
    end

    def canonical_type(content_type)
      type = normalized_type(content_type)
      TYPE_ALIASES.fetch(type, type)
    end
  end
end
