# Extracts text from the masked body of an FoiAttachment for search indexing
class AttachmentToText
  MS_WORD_DOCS = %w[
    application/vnd.openxmlformats-officedocument.wordprocessingml.document
    application/vnd.ms-word
    application/vnd.ms-word.document.macroenabled.12
  ].freeze

  WORD_PROCESSING_DOCS = %w[
    application/vnd.oasis.opendocument.text
    application/vnd.oasis.opendocument.text-template
    application/vnd.oasis.opendocument.text-flat-xml
    application/vnd.sun.xml.writer
    application/vnd.sun.xml.writer.template
  ].freeze

  MS_POWERPOINT_DOCS = %w[
    application/vnd.openxmlformats-officedocument.presentationml.presentation
    application/vnd.ms-powerpoint
    application/vnd.ms-powerpoint.presentation.macroenabled.12
    application/vnd.ms-powerpoint.slideshow.macroenabled.12
  ].freeze

  PRESENTATION_DOCS = %w[
    application/vnd.oasis.opendocument.presentation
    application/vnd.oasis.opendocument.presentation-template
    application/vnd.oasis.opendocument.presentation-flat-xml
  ].freeze

  MS_EXCEL_DOCS = %w[
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
    application/vnd.ms-excel
    application/vnd.ms-excel.sheet.macroenabled.12
    application/vnd.ms-excel.sheet.binary.macroenabled.12
  ].freeze

  SPREADSHEET_DOCS = %w[
    application/vnd.oasis.opendocument.spreadsheet
    application/vnd.oasis.opendocument.spreadsheet-template
    application/vnd.oasis.opendocument.spreadsheet-flat-xml
  ].freeze

  # Extensionless sandbox input name; converters derive output names from it.
  INPUT_NAME = 'foiextract'.freeze

  MAX_TEXT = 128 * 1024 * 1024
  MAX_ZIP_DEPTH = 2
  MAX_ZIP_ENTRIES = 500
  MAX_ZIP_ENTRY = 25 * 1024 * 1024
  MAX_ZIP_TOTAL = 50 * 1024 * 1024

  # LibreOffice reserves far more address space than it uses.
  LIBREOFFICE_MEMORY = 4 * 1024 * 1024 * 1024

  # If set OCR will be attempted if the extracted text length is below the
  # configured threshold. Extraction-only (distinct from PDFRedactor::Ocr).
  cattr_accessor :pdf_ocr_threshold, default: nil

  # Raised when maskable formats (PDF, HTML) fail conversion so MainBody retries
  # instead of caching empty text. Zip-based office formats return '' instead
  # (censor rules cannot mask their compressed content; see doc/FORK.md).
  ConversionFailed = Class.new(StandardError)

  # Temporary compatibility interface
  def self.from_part(part, text)
    interface = OpenStruct.new(
      content_type: part.content_type,
      default_body: text
    )

    new(interface)
  end

  # Temporary compatibility interface
  def self.from_string(str, content_type: 'text/plain')
    interface = OpenStruct.new(
      content_type: content_type,
      default_body: str
    )

    new(interface)
  end

  def initialize(attachment)
    @attachment = attachment
  end

  def to_text
    text = extract_text(attachment.default_body, attachment.content_type)
    convert_string_to_utf8(text, 'UTF-8').string
  end

  protected

  attr_reader :attachment

  private

  def extract_text(body, content_type, zip_depth: 0, zip_budget: nil)
    # NOTE: re. charset: TMail always tries to convert email bodies
    # to UTF8 by default, so normally it should already be that.
    # TODO: - tell all these command line tools to return utf-8
    case content_type
    when 'text/html'           then extract_html(body)
    when 'application/pdf'     then extract_pdf(body)
    when *MS_WORD_DOCS         then extract_ms_word(body)
    when *WORD_PROCESSING_DOCS then extract_word_processing(body)
    when *MS_EXCEL_DOCS        then extract_ms_excel(body)
    when *SPREADSHEET_DOCS     then extract_spreadsheet(body)
    when *MS_POWERPOINT_DOCS   then extract_ms_powerpoint(body)
    when *PRESENTATION_DOCS    then extract_presentation(body)
    when 'application/rtf'     then extract_rtf(body)
    when 'application/zip'
      extract_zip(body, depth: zip_depth,
                        budget: zip_budget || { entries: 0, bytes: 0 })
    when /\Atext\// then extract_plain(body)
    else ''
    end
  end

  def extract_plain(body)
    body + "\n\n"
  end

  def extract_html(body, charset: 'utf-8')
    text = convert(body) do |job|
      # lynx wordwraps links in its output, which then don't
      # get formatted properly by Alaveteli. We use elinks
      # instead, which doesn't do that.
      stdout_text job.run(
        'elinks',
        '-eval', "set document.codepage.assume = \"#{charset}\"",
        '-eval', 'set document.codepage.force_assumed = 1',
        '-dump-charset', 'utf-8',
        '-force-html', '-dump',
        job.input,
        timeout: 5.minutes, stdout: MAX_TEXT,
        env: { 'LANG' => 'C' }
      )
    end
    raise ConversionFailed, 'HTML (elinks) conversion failed' if text.nil?

    text
  end

  def extract_rtf(body)
    extract_word_processing(body)
  end

  def extract_pdf(body)
    text = extract_text_pdf(body)

    if above_ocr_threshold?(text)
      text
    else
      ocr_pdf(body)
    end
  end

  def above_ocr_threshold?(text)
    return true if pdf_ocr_threshold.nil?

    text.length >= pdf_ocr_threshold
  end

  def extract_text_pdf(body)
    text = convert(body) do |job|
      stdout_text job.run(
        'pdftotext', job.input, '-', timeout: 5.minutes, stdout: MAX_TEXT
      )
    end
    # Before extract_pdf reads text.length against the OCR threshold.
    raise ConversionFailed, 'PDF (pdftotext) conversion failed' if text.nil?

    text
  end

  # Not Implemented Yet: Hook provided for easier experimentation.
  def ocr_pdf(_body)
    ''
  end

  def extract_ms_word(body)
    extract_word_processing(body)
  end

  def extract_word_processing(body)
    text = convert(body) do |job|
      libreoffice(job, 'txt:Text (encoded):UTF8')

      # LibreOffice writes no output when it fails or times out
      output = "#{INPUT_NAME}.txt"
      job.exist?(output) ? utf8(job.read(output, max: MAX_TEXT)) : ''
    end
    text || ''
  end

  def extract_ms_powerpoint(body)
    extract_presentation(body)
  end

  def extract_presentation(body)
    text = convert(body) do |job|
      libreoffice(job, 'pdf')

      stdout_text job.run(
        'pdftotext', job.scratch("#{INPUT_NAME}.pdf"), '-',
        timeout: 5.minutes, stdout: MAX_TEXT
      )
    end
    text || ''
  end

  def extract_ms_excel(body)
    extract_spreadsheet(body)
  end

  # 44 = comma field separator.
  # 34 = double-quote text delimiter.
  # 76 = UTF-8 character set.
  # 1 = start from row 1.
  # empty token 5 = no column-specific format overrides.
  # 0 = default/UI language.
  # false = quoted fields are not forced to text.
  # true = export number cells as numbers.
  # false = do not use "save cell contents as shown"; export underlying values
  #   instead.
  # false = do not export formulas; export values.
  # empty token 11 = unused here; token 11 is only for CSV import ("remove
  #   spaces").
  # -1 in token 12 = export all sheets to separate files like sample-Sheet1.csv,
  #   sample-Sheet2.csv.
  def extract_spreadsheet(body)
    csv_filters = '(StarCalc):44,34,76,1,,0,false,true,false,false,,-1'

    text = convert(body) do |job|
      libreoffice(job, "csv:Text - txt - csv #{csv_filters}")

      combine_csv_files_with_sheet_names(job).squeeze(',')
    end
    text || ''
  end

  def combine_csv_files_with_sheet_names(job)
    job.files(/\.csv\z/).each_with_object(+'') do |name, memo|
      # Remove the .csv extension and input name prefix, leaving the sheet name
      sheet_name = File.basename(name, '.csv').gsub("#{INPUT_NAME}-", '')
      header = "=== #{sheet_name} ===\n\n"
      remaining = MAX_TEXT - memo.bytesize - header.bytesize - 1
      break memo if remaining.negative?

      content =
        begin
          utf8(job.read(name, max: remaining))
        rescue AlaveteliSandbox::LimitExceeded
          break memo
        end

      memo << "#{header}#{content}\n"
    end.chomp
  end

  # Runs sandboxed converter steps; returns nil on sandbox failure (logged).
  def convert(body, &block)
    AlaveteliSandbox.job(input: body, input_name: INPUT_NAME, &block)
  rescue AlaveteliSandbox::Error
    nil
  end

  def libreoffice(job, format)
    job.run('libreoffice', '--headless', '--convert-to', format, job.input,
            timeout: 5.minutes, memory: LIBREOFFICE_MEMORY)
  end

  def stdout_text(result)
    utf8(result.stdout)
  end

  def utf8(data)
    data.force_encoding(Encoding::UTF_8)
  end

  def extract_zip(body, depth:, budget:)
    return '' if depth >= MAX_ZIP_DEPTH

    text = +''
    skip = 0
    loop do
      max_entries = MAX_ZIP_ENTRIES - budget[:entries]
      max_total = MAX_ZIP_TOTAL - budget[:bytes]
      break if max_entries <= 0 || max_total <= 0 ||
               text.bytesize >= MAX_TEXT || skip >= MAX_ZIP_ENTRIES

      zip = { max_entries: max_entries,
              max_entry: [MAX_ZIP_ENTRY, max_total].min,
              max_total: max_total,
              skip: skip }
      resume_at = extract_zip_pass(body, text, depth: depth, budget: budget,
                                               zip: zip)
      break unless resume_at

      skip = resume_at
    end
    text
  end

  def extract_zip_pass(body, text, depth:, budget:, zip:)
    OfficePackage::Isolated.read_zip(bytes: body, zip: zip) do |read|
      read.value('guard')
      extract_zip_entries(read, text, depth: depth, budget: budget,
                                      skip: zip[:skip])
    end
  rescue AlaveteliSandbox::Error
    raise
  rescue StandardError
    $stderr.puts("Error processing zip file: #{$ERROR_INFO.inspect}")
    nil
  end

  def extract_zip_entries(read, text, depth:, budget:, skip: 0)
    yielded = 0
    resume_at = nil
    seen = read.each_zip_entry do |filename, entry_body|
      budget[:entries] += 1
      yielded += 1
      break if budget[:entries] > MAX_ZIP_ENTRIES ||
               budget[:bytes] >= MAX_ZIP_TOTAL

      if budget[:bytes] + entry_body.bytesize > MAX_ZIP_TOTAL
        resume_at = next_zip_resume(read, skip, yielded, budget)
        break if resume_at

        next
      end

      budget[:bytes] += entry_body.bytesize
      text << extract_zip_entry(filename, entry_body,
                                depth: depth, budget: budget)
      break if text.bytesize >= MAX_TEXT
    end
    if !resume_at && seen.is_a?(Integer) && seen > yielded
      budget[:entries] += seen - yielded
    end
    resume_at
  end

  def next_zip_resume(read, skip, yielded, budget)
    index = read.respond_to?(:last_zip_index) ? read.last_zip_index : nil
    return nil unless index

    seen_so_far = index - skip + 1
    budget[:entries] += seen_so_far - yielded if seen_so_far > yielded
    index + 1
  end

  def extract_zip_entry(filename, body, depth:, budget:)
    content_type = AlaveteliFileTypes.filename_to_mimetype(filename) ||
                   'application/octet-stream'
    if content_type == 'text/plain' && body.encoding.to_s == 'ASCII-8BIT'
      body = convert_string_to_utf8(body, 'ASCII-8BIT').string
    end
    extract_text(body, content_type,
                 zip_depth: depth + 1, zip_budget: budget)
  end
end
