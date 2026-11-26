require 'csv'
require 'date'
require_relative 'attachment_fixtures'

# Invented content only; telephone numbers are in Ofcom's drama range
# (01632 960xxx). ImageMagick only writes images here, as its usual security
# policy forbids PDF.
module DocumentFixtures
  PAGE = [595, 842].freeze # A4, in points
  LEFT = 72
  # Baselines (points from the bottom) of the two lines on decision_letter_pdf's
  # page 1 that salutation_box and officer_box cover.
  SALUTATION_Y = 668
  OFFICER_Y = 200
  LEAFLET_FILENAME = 'foi-complaints-procedure.pdf'.freeze
  SPREADSHEET_NS =
    'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" ' \
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/' \
    'relationships"'.freeze

  SECTION_43 = 'Some of the information you asked for is withheld under ' \
               'section 43(2) of the Act (commercial interests): releasing ' \
               'it would be likely to prejudice the commercial interests of ' \
               'the authority and its contractors. We have considered the ' \
               'public interest and concluded that it favours withholding ' \
               'this information.'.freeze
  RIGHTS = 'If you are unhappy with the way your request has been handled, ' \
           'you can ask for an internal review. Please write to us within 40 ' \
           'working days of the date of this letter. If you are still ' \
           'dissatisfied after the review, you can complain to the ' \
           'Information Commissioner.'.freeze

  # top: and floor: apply to page 1 only.
  class Layout
    attr_reader :pages

    def initialize(top: 780, floor: 72)
      @pages = [{ texts: [] }]
      @top = 780
      @y = top
      @floor = floor
    end

    def at(x, y, text, size)
      return if text.to_s.empty?

      @pages.last[:texts] << { x: x,
                               y: y,
                               text: DocumentFixtures.ascii(text),
                               size: size }
    end

    def line(text, size: 11, leading: 15, x: LEFT)
      new_page if @y < @floor
      at(x, @y, text, size)
      @y -= leading
    end

    def paragraph(text, size: 11, leading: 15, width: 80, gap: 9)
      DocumentFixtures.wrap(text, width).each do |part|
        line(part, size: size, leading: leading)
      end
      @y -= gap
    end

    def new_page(floor: 72)
      @pages << { texts: [] }
      @y = @top
      @floor = floor
    end
  end

  module_function

  # The case officer's name and number appear only on page 1's OFFICER_Y line
  # (the sign-off names a team), so a box over officer_box removes them.
  def decision_letter_pdf(requester:, authority:, ref:, paragraphs:,
                          officer: 'Alex Placeholder',
                          phone: '01632 960123',
                          date: nil,
                          withheld: SECTION_43,
                          info: {})
    layout = Layout.new(top: 612, floor: OFFICER_Y + 32)
    heading(layout, authority, ref, date)
    layout.at(LEFT, SALUTATION_Y, "Dear #{requester},", 12)
    layout.at(LEFT, 640, "Freedom of Information request #{ref}", 12)
    layout.paragraph('Thank you for your request for information. We have ' \
                     'dealt with your request under the Freedom of ' \
                     'Information Act 2000.')
    Array(paragraphs).each { |text| layout.paragraph(text) }
    layout.paragraph(withheld) if withheld
    layout.pages.first[:texts] << {
      x: LEFT,
      y: OFFICER_Y,
      size: 12,
      text: ascii("Case officer: #{officer}, telephone #{phone}")
    }
    layout.new_page if layout.pages.size == 1
    layout.paragraph(RIGHTS)
    sign_off(layout, 'Information Governance Team', authority)
    AttachmentFixtures.pdf(pages: layout.pages, info: info)
  end

  # Its text and LEAFLET_FILENAME each match a LetterPick leaflet rule, so
  # either rule sets it aside.
  def leaflet_pdf(authority: 'the authority')
    layout = Layout.new
    layout.line('Freedom of Information: complaints procedure',
                size: 16,
                leading: 28)
    layout.paragraph("This leaflet explains the complaints procedure for " \
                     "requests for information made to #{authority}.")
    layout.paragraph('Asking for an internal review. If you are unhappy with ' \
                     'the way your request was handled, write to us within ' \
                     '40 working days of our reply and say what you would ' \
                     'like us to look at again.')
    layout.paragraph('How the review works. A senior officer who was not ' \
                     'involved in the original decision looks at your ' \
                     'request again and replies within 20 working days.')
    layout.paragraph('If you are still unhappy. You can complain to the ' \
                     'Information Commissioner, who regulates the Freedom of ' \
                     'Information Act 2000.')
    layout.paragraph('Re-using information. Most information we release can ' \
                     'be re-used under the Open Government Licence unless we ' \
                     'tell you otherwise.')
    AttachmentFixtures.pdf(pages: layout.pages)
  end

  # Fractional [x0, y0, x1, y1] from top-left (AttachmentManagement::Boxes).
  def officer_box
    line_box(OFFICER_Y, 12)
  end

  def salutation_box
    line_box(SALUTATION_Y, 12)
  end

  def line_box(baseline, size, page: PAGE)
    width, height = page
    top = baseline + (size * 1.2)
    bottom = baseline - (size * 0.6)
    [(LEFT - 8.0) / width,
     (height - top) / height,
     (width - LEFT + 8.0) / width,
     (height - bottom) / height].map { |value| value.round(4) }
  end

  # No decision wording, so the Suggester sets it aside.
  def acknowledgement_pdf(requester:, authority:, ref:, date: nil)
    layout = Layout.new(top: 612)
    heading(layout, authority, ref, date)
    layout.at(LEFT, SALUTATION_Y, "Dear #{requester},", 12)
    layout.at(LEFT, 640, "Request for information #{ref}", 12)
    layout.paragraph("Thank you for your request for information, which we " \
                     "received on #{long_date(date)}.")
    layout.paragraph("Your request has been logged under reference #{ref} " \
                     'and is now being considered under the Freedom of ' \
                     'Information Act 2000. We will respond promptly, and no ' \
                     'later than 20 working days after the day we received it.')
    layout.paragraph('Please quote the reference above if you contact us ' \
                     'about your request.')
    sign_off(layout, 'Information Governance Team', authority)
    AttachmentFixtures.pdf(pages: layout.pages)
  end

  def text_pdf(title:, paragraphs:)
    layout = Layout.new
    layout.line(title, size: 16, leading: 28)
    Array(paragraphs).each { |text| layout.paragraph(text) }
    AttachmentFixtures.pdf(pages: layout.pages)
  end

  # Each column starts at a fixed x offset wide enough for its longest cell,
  # so `pdftotext -layout` keeps the columns apart.
  def table_pdf(title:, headers:, rows:, note: nil, size: 10)
    cells = [headers, *rows].map { |row| row.map { |cell| ascii(cell) } }
    widths = (0...headers.size).map do |c|
      cells.map { |row| row[c].to_s.size }.max
    end
    # Helvetica averages about 0.62 em a character; columns are two ems apart.
    measure = ->(points) do
      widths.sum { |chars| chars * points * 0.62 } +
        (points * 2 * (widths.size - 1))
    end
    width, height = PAGE
    width, height = height, width if measure.call(size) > width - 100
    if measure.call(size) > width - 100
      size = [(size * (width - 100) / measure.call(size)).floor(1), 4].max
    end
    x = 50.0
    columns = widths.map do |chars|
      x.round(1).tap { x += (chars * size * 0.62) + (size * 2) }
    end
    leading = size + 6
    pages = []
    header, *body = cells
    body = [[]] if body.empty?
    body.each do |row|
      if pages.empty? || pages.last[:y] - leading < 60
        page = { size: [width, height], texts: [], y: height - 60 }
        page[:texts] << { x: 50, y: page[:y], text: ascii(title), size: 14 }
        page[:y] -= 20
        if note
          page[:texts] << { x: 50, y: page[:y], text: ascii(note), size: 9 }
          page[:y] -= 18
        end
        page[:y] -= 12
        header.each_with_index do |cell, c|
          page[:texts] << { x: columns[c],
                            y: page[:y],
                            text: cell,
                            size: size }
        end
        page[:y] -= leading + 4
        pages << page
      end
      page = pages.last
      row.each_with_index do |cell, c|
        unless cell.to_s.empty?
          page[:texts] << { x: columns[c],
                            y: page[:y],
                            text: cell,
                            size: size }
        end
      end
      page[:y] -= leading
    end
    AttachmentFixtures.pdf(pages: pages.map { |page| page.except(:y) })
  end

  # Image-only PDF (no text layer). lines: one page or array of pages.
  def scanned_pdf(lines:, point_size: 30)
    pages = (lines.first.is_a?(Array) ? lines : [lines]).flat_map do |page|
      slices = page.flat_map { |text|
        text.to_s.strip.empty? ? [''] : wrap(text, 56)
      }.each_slice(scan_lines_per_page(point_size)).to_a
      slices.empty? ? [[]] : slices
    end
    objects = [nil, nil]
    color_spaces = { 1 => '/DeviceGray', 3 => '/DeviceRGB', 4 => '/DeviceCMYK' }
    page_ids = pages.map do |page_lines|
      jpeg = scan_jpeg(page_lines, point_size: point_size)
      width, height, components = jpeg_size(jpeg)
      space = color_spaces.fetch(components)
      objects << ("<< /Type /XObject /Subtype /Image /Width #{width} " \
                 "/Height #{height} /ColorSpace #{space} " \
                 "/BitsPerComponent 8 /Filter /DCTDecode " \
                 "/Length #{jpeg.bytesize} >>\nstream\n".b +
                 jpeg.b + "\nendstream".b)
      image = objects.size
      content = "q #{PAGE[0]} 0 0 #{PAGE[1]} 0 0 cm /Scan Do Q"
      objects << "<< /Length #{content.bytesize} >>\nstream\n" \
                 "#{content}\nendstream"
      stream = objects.size
      objects << "<< /Type /Page /Parent 2 0 R " \
                 "/MediaBox [0 0 #{PAGE[0]} #{PAGE[1]}] " \
                 "/Resources << /XObject << /Scan #{image} 0 R >> >> " \
                 "/Contents #{stream} 0 R >>"
      objects.size
    end
    objects[0] = '<< /Type /Catalog /Pages 2 0 R >>'
    objects[1] = "<< /Type /Pages " \
                 "/Kids [#{page_ids.map { |id| "#{id} 0 R" }.join(' ')}] " \
                 "/Count #{page_ids.size} >>"
    AttachmentFixtures.write(objects, root: 1, info: nil)
  end

  # Searchable scan whose invisible text layer (3 Tr) differs from the image;
  # contrast checks see the scan underneath and retain the text.
  def searchable_scan_pdf
    jpeg = scan_jpeg(
      ['North depot: twelve vans and four gritters in January',
       'South depot: nine vans and two gritters in February']
    )
    width, height, components = jpeg_size(jpeg)
    space = { 1 => '/DeviceGray', 3 => '/DeviceRGB' }.fetch(components)
    content = "q 595 0 0 842 0 0 cm /Scan Do Q\n" \
              "BT 3 Tr /F1 11 Tf 72 761 Td (Zebrafinch Quillwort " \
              "Marshwren) Tj ET\n" \
              'BT 3 Tr /F1 11 Tf 72 738 Td (Peregrine Hollyoak ' \
              'Kestrelmoor) Tj ET'
    image = "<< /Type /XObject /Subtype /Image /Width #{width} /Height " \
            "#{height} /ColorSpace #{space} /BitsPerComponent 8 /Filter " \
            "/DCTDecode /Length #{jpeg.bytesize} >>\nstream\n".b +
            jpeg.b + "\nendstream".b
    AttachmentFixtures.write(
      ['<< /Type /Catalog /Pages 2 0 R >>',
       '<< /Type /Pages /Kids [5 0 R] /Count 1 >>',
       '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
       image,
       '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << ' \
       '/Font << /F1 3 0 R >> /XObject << /Scan 4 0 R >> >>' \
       ' /Contents 6 0 R >>',
       "<< /Length #{content.bytesize} >>\nstream\n#{content}\nendstream"],
      root: 1,
      info: nil
    )
  end

  def scan_jpeg(lines, point_size: 30)
    y = 170
    step = (point_size * 1.6).round
    draws = lines.flat_map do |text|
      draw = if text.to_s.strip.empty?
               []
             else
               ['-annotate', "+150+#{y}", magick_text(text)]
             end
      y += step
      draw
    end
    AttachmentFixtures.magick('-size', '1240x1754', 'xc:white',
                              '-fill', 'black',
                              '-pointsize', point_size.to_s,
                              *draws,
                              '-blur', '0x0.6',
                              '-colorspace', 'Gray',
                              '-quality', '82',
                              '-strip', 'jpeg:-')
  end

  # Lines that fit between the top margin (170 px) and a 100 px bottom margin.
  def scan_lines_per_page(point_size)
    [(1754 - 170 - 100) / (point_size * 1.6).round, 1].max
  end

  # [width, height, components] from a JPEG's frame header.
  def jpeg_size(jpeg)
    data = jpeg.b
    index = 2
    while index + 9 < data.bytesize
      index += 1 while data.getbyte(index + 1) == 0xFF
      marker = data.getbyte(index + 1)
      length = data.byteslice(index + 2, 2).unpack1('n')
      if [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
          0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF].include?(marker)
        height, width = data.byteslice(index + 5, 4).unpack('nn')
        return [width, height, data.getbyte(index + 9)]
      end
      index += 2 + length
    end
    raise ArgumentError, 'not a JPEG with a frame header'
  end

  # One row of [value, xfs index] cells. formats are custom number formats
  # (ids from 164); xfs are [numFmtId, fontId], font 1 white on no fill.
  def styled_xlsx(cells, formats:, xfs:)
    main = 'application/vnd.openxmlformats-officedocument.spreadsheetml'
    row = cells.each_with_index.map do |(value, style), index|
      ref = "#{column_letter(index + 1)}1"
      if value.is_a?(String)
        %(<c r="#{ref}" s="#{style}" t="inlineStr"><is><t>) \
          "#{AttachmentFixtures.xml_escape(value)}</t></is></c>"
      else
        %(<c r="#{ref}" s="#{style}"><v>#{value}</v></c>)
      end
    end.join
    numbers = formats.each_with_index.map do |code, index|
      %(<numFmt numFmtId="#{164 + index}" formatCode=") \
        "#{AttachmentFixtures.xml_escape(code).gsub('"', '&quot;')}" \
        '"/>'
    end.join
    fonts = '<fonts count="2"><font><sz val="11"/><color theme="1"/></font>' \
            '<font><sz val="11"/><color rgb="FFFFFFFF"/></font></fonts>'
    fills = '<fills count="2"><fill><patternFill patternType="none"/></fill>' \
            '<fill><patternFill patternType="gray125"/></fill></fills>'
    cell_xfs = xfs.map do |number, font|
      %(<xf numFmtId="#{number}" fontId="#{font}" fillId="0" xfId="0"/>)
    end.join
    AttachmentFixtures.ooxml(
      '[Content_Types].xml' => AttachmentFixtures.content_types(
        '/xl/workbook.xml' => "#{main}.sheet.main+xml",
        '/xl/worksheets/sheet1.xml' => "#{main}.worksheet+xml",
        '/xl/styles.xml' => "#{main}.styles+xml"
      ),
      '_rels/.rels' =>
        AttachmentFixtures.rels('officeDocument' => 'xl/workbook.xml'),
      'xl/workbook.xml' =>
        %(<workbook #{SPREADSHEET_NS}><sheets>) \
        '<sheet name="Figures" sheetId="1" r:id="rId1"/></sheets></workbook>',
      'xl/_rels/workbook.xml.rels' => AttachmentFixtures.rels(
        'worksheet' => 'worksheets/sheet1.xml',
        'styles' => 'styles.xml'
      ),
      'xl/styles.xml' =>
        %(<styleSheet #{SPREADSHEET_NS}>) \
        "<numFmts count=\"#{formats.size}\">#{numbers}</numFmts>" \
        "#{fonts}#{fills}" + "<cellXfs count=\"#{xfs.size}\">#{cell_xfs}" \
        '</cellXfs></styleSheet>',
      'xl/worksheets/sheet1.xml' =>
        %(<worksheet #{SPREADSHEET_NS}><sheetData><row r="1">#{row}</row>) \
        '</sheetData></worksheet>'
    )
  end

  # sheets: [{ name:, rows:, hidden: (true or :very), hidden_rows:,
  # hidden_columns: }], rows and columns 1-based, columns also as letters.
  def xlsx(sheets:, creator: 'Information Governance', shared_strings: true)
    strings = []
    lookup = {}
    uses = 0
    shared = if shared_strings
               ->(text) do
                 uses += 1
                 lookup[text] ||= (strings << text).size - 1
               end
             end
    worksheets = sheets.each_with_index.map do |sheet, index|
      ["xl/worksheets/sheet#{index + 1}.xml", worksheet(sheet, shared)]
    end
    hidden_states = {
      true => ' state="hidden"',
      :very => ' state="veryHidden"'
    }
    entries = sheets.each_with_index.map do |sheet, index|
      state = hidden_states.fetch(sheet[:hidden], '')
      %(<sheet name="#{AttachmentFixtures.xml_escape(sheet.fetch(:name))}") \
        " sheetId=\"#{index + 1}\"#{state} r:id=\"rId#{index + 1}\"/>"
    end.join
    main = 'application/vnd.openxmlformats-officedocument.spreadsheetml'
    overrides = { '/xl/workbook.xml' => "#{main}.sheet.main+xml" }
    worksheets.each do |path, _|
      overrides["/#{path}"] = "#{main}.worksheet+xml"
    end
    if strings.any?
      overrides['/xl/sharedStrings.xml'] = "#{main}.sharedStrings+xml"
    end
    overrides['/docProps/core.xml'] =
      'application/vnd.openxmlformats-package.core-properties+xml'
    targets = {
      'worksheet' => worksheets.map { |path, _| path.delete_prefix('xl/') }
    }
    targets['sharedStrings'] = 'sharedStrings.xml' if strings.any?
    files = {
      '[Content_Types].xml' => AttachmentFixtures.content_types(overrides),
      '_rels/.rels' => AttachmentFixtures.rels(
        'officeDocument' => 'xl/workbook.xml',
        'metadata/core-properties' => 'docProps/core.xml'
      ),
      'xl/workbook.xml' =>
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' \
        "<workbook #{SPREADSHEET_NS}><sheets>#{entries}</sheets></workbook>",
      'xl/_rels/workbook.xml.rels' => AttachmentFixtures.rels(targets)
    }
    worksheets.each { |path, xml| files[path] = xml }
    if strings.any?
      items = strings.map do |text|
        %(<si><t xml:space="preserve">) \
          "#{AttachmentFixtures.xml_escape(text)}</t></si>"
      end.join
      files['xl/sharedStrings.xml'] =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><sst ' \
        'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" ' \
        "count=\"#{uses}\" uniqueCount=\"#{strings.size}\">#{items}</sst>"
    end
    files['docProps/core.xml'] = AttachmentFixtures.core_properties(creator)
    AttachmentFixtures.ooxml(files)
  end

  def worksheet(sheet, shared)
    hidden_rows = Array(sheet[:hidden_rows]).map(&:to_i)
    hidden_columns = Array(sheet[:hidden_columns]).
      map { |column| column_number(column) }.uniq.sort
    cols = hidden_columns.map do |n|
      %(<col min="#{n}" max="#{n}" width="14" customWidth="1" hidden="1"/>)
    end.join
    data = sheet.fetch(:rows).each_with_index.map do |row, r|
      cells = row.each_with_index.filter_map do |value, c|
        cell_xml("#{column_letter(c + 1)}#{r + 1}", value, shared)
      end
      %(<row r="#{r + 1}"#{' hidden="1"' if hidden_rows.include?(r + 1)}>) \
        "#{cells.join}</row>"
    end.join
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' \
      "<worksheet #{SPREADSHEET_NS}>" \
      "#{"<cols>#{cols}</cols>" unless cols.empty?}" \
      "<sheetData>#{data}</sheetData></worksheet>"
  end

  def cell_xml(ref, value, shared)
    case value
    when nil then nil
    when true, false then %(<c r="#{ref}" t="b"><v>#{value ? 1 : 0}</v></c>)
    when Integer, Float then %(<c r="#{ref}"><v>#{value}</v></c>)
    else
      text = value.to_s
      if shared
        %(<c r="#{ref}" t="s"><v>#{shared.call(text)}</v></c>)
      else
        %(<c r="#{ref}" t="inlineStr"><is><t xml:space="preserve">) \
          "#{AttachmentFixtures.xml_escape(text)}</t></is></c>"
      end
    end
  end

  def column_letter(number)
    letters = +''
    while number.positive?
      number, remainder = (number - 1).divmod(26)
      letters.prepend((65 + remainder).chr)
    end
    letters
  end

  def column_number(column)
    return column.to_i if column.is_a?(Integer) || column.to_s.match?(/\A\d+\z/)

    column.to_s.upcase.each_char.
      reduce(0) { |sum, char| (sum * 26) + (char.ord - 64) }
  end

  def csv(rows)
    CSV.generate { |out| rows.each { |row| out << row } }
  end

  def zip(files)
    AttachmentFixtures.ooxml(files.to_h)
  end

  def docx(paragraphs:)
    AttachmentFixtures.docx(paragraphs: paragraphs)
  end

  def signature_png
    AttachmentFixtures.magick('-size', '360x110', 'xc:white',
                              '-fill', 'none',
                              '-stroke', '#1b2a6b',
                              '-strokewidth', '3',
                              '-draw', "path 'M 20,80 C 50,10 80,100 110,50 " \
                                       'S 170,20 190,70 S 250,90 280,40 ' \
                                       "S 330,60 345,55'",
                              '-depth', '8',
                              '-strip', 'png:-')
  end

  # Text folded to what Helvetica's standard encoding can show.
  def ascii(text)
    text.to_s.tr("‘’“”–— ", %('\'""-- )).gsub("£", 'GBP ').
      gsub("…", '...').
      encode('ASCII', invalid: :replace, undef: :replace, replace: '?')
  end

  def wrap(text, width)
    text.to_s.split("\n").flat_map do |source|
      lines = source.split.each_with_object([+'']) do |word, out|
        if out.last.empty?
          out.last << word
        elsif out.last.size + 1 + word.size <= width
          out.last << ' ' << word
        else
          out << word.dup
        end
      end
      lines
    end
  end

  # ImageMagick's -annotate reads %-escapes and an initial @ (a file name).
  def magick_text(text)
    ascii(text).delete_prefix('@').gsub('%', '%%').gsub('\\', '\\\\\\\\')
  end

  def long_date(date)
    (date || today).strftime('%-d %B %Y')
  end

  def today
    Date.respond_to?(:current) ? Date.current : Date.today
  end

  def heading(layout, authority, ref, date)
    layout.at(LEFT, 790, authority, 16)
    layout.at(LEFT, 772, 'Information Governance', 10)
    layout.at(400, 744, "Our ref: #{ref}", 10)
    layout.at(400, 730, "Date: #{long_date(date)}", 10)
  end

  def sign_off(layout, team, authority)
    layout.line('Yours sincerely,', leading: 30)
    layout.line(team)
    layout.line(authority)
  end
end
