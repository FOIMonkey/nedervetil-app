module AttachmentFixtures
  module_function

  # Each page: { size: [595, 842], crop_box:, rotate:, note:,
  #   texts: [{ x:, y:, text:, size: 14, colour: [0, 0, 0] }],
  #   boxes: [{ x:, y:, w:, h:, colour: }] (drawn after text) }
  def pdf(pages:, info: {})
    objects = []
    add = ->(body) do
      objects << body
      objects.size
    end

    catalog = add.call(nil)
    pages_id = add.call(nil)
    font = add.call('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>')

    page_ids = pages.map do |page|
      width, height = page.fetch(:size, [595, 842])
      content = page_content(page)
      stream = add.call("<< /Length #{content.bytesize} >>\nstream\n" \
                        "#{content}\nendstream")
      annots = ''
      if page[:note]
        note = add.call(
          "<< /Type /Annot /Subtype /Text /Rect [20 20 40 40] " \
          "/Contents (#{escape(page[:note])}) >>"
        )
        annots = " /Annots [#{note} 0 R]"
      end
      crop = page[:crop_box] ? " /CropBox [#{page[:crop_box].join(' ')}]" : ''
      rotate = page[:rotate] ? " /Rotate #{page[:rotate]}" : ''
      add.call(
        "<< /Type /Page /Parent #{pages_id} 0 R " \
        "/MediaBox [0 0 #{width} #{height}]" \
        "#{crop}#{rotate} /Resources << /Font << /F1 #{font} 0 R >> >> " \
        "/Contents #{stream} 0 R#{annots} >>"
      )
    end

    objects[catalog - 1] = "<< /Type /Catalog /Pages #{pages_id} 0 R >>"
    objects[pages_id - 1] =
      "<< /Type /Pages " \
      "/Kids [#{page_ids.map { |id| "#{id} 0 R" }.join(' ')}] " \
      "/Count #{page_ids.size} >>"

    info_id = nil
    if info.any?
      entries = info.map do |key, value|
        "/#{key} (#{escape(value)})"
      end.join(' ')
      info_id = add.call("<< #{entries} >>")
    end

    write(objects, root: catalog, info: info_id)
  end

  def letter_page(secret:, heading: 'Response to your request', **options)
    {
      texts: [
        { x: 72, y: 760, text: heading, size: 18 },
        { x: 72, y: 600, text: secret, size: 16 },
        { x: 72, y: 120, text: 'Information Rights Team', size: 12 }
      ]
    }.merge(options)
  end

  def xmp_pdf(creator:, text: 'The depot opens at eight each weekday.')
    xmp = '<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>' \
          '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF ' \
          'xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">' \
          '<rdf:Description rdf:about="" ' \
          'xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:creator>' \
          "<rdf:Seq><rdf:li>#{xml_escape(creator)}</rdf:li></rdf:Seq>" \
          '</dc:creator></rdf:Description></rdf:RDF></x:xmpmeta>' \
          '<?xpacket end="w"?>'
    content = "BT /F1 12 Tf 72 760 Td (#{escape(text)}) Tj ET"
    write(
      ['<< /Type /Catalog /Pages 2 0 R /Metadata 6 0 R >>',
       '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
       '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] ' \
       '/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
       '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
       "<< /Length #{content.bytesize} >>\nstream\n#{content}\nendstream",
       "<< /Type /Metadata /Subtype /XML /Length #{xmp.bytesize} >>\n" \
       "stream\n#{xmp}\nendstream"],
      root: 1, info: nil
    )
  end

  def letter_secret_box
    [0.08, 0.26, 0.92, 0.31]
  end

  # letter_page's secret line under /Rotate 90 (landscape, 600pt from bottom).
  def rotated_secret_box
    [0.69, 0.07, 0.75, 0.75]
  end

  def deliver(info_request, files, text: "Please find our response attached.\n\nJane Example\n")
    mail = Mail.new
    mail.from = 'Information Rights <foi@synthetic-authority.test>'
    mail.to = info_request.incoming_email
    mail.subject = "RE: Freedom of Information request - #{info_request.title}"
    mail.date = Time.zone.now
    mail.message_id = "<#{SecureRandom.hex(10)}@synthetic.test>"
    mail.text_part = Mail::Part.new.tap { |part| part.body = text }
    files.each do |name, type, bytes|
      mail.attachments[name] = { mime_type: type, content: bytes }
    end
    message = info_request.receive(Mail.from_source(mail.encoded)) or return
    parsed(message)
  end

  # Retry on a fresh record: MaskJob can re-parse concurrently before the
  # first parse's commit callbacks finish writing the file.
  def parsed(message, attempts: 5)
    IncomingMessage.find(message.id).tap(&:parse_raw_email)
  rescue Errno::ENOENT, ActiveStorage::FileNotFoundError
    raise if (attempts -= 1).zero?

    sleep 1
    retry
  end

  # lines: [[x, y, text], ...] in pixels from the top left.
  def image(lines:, width: 800, height: 500, format: 'png', point_size: 36)
    draws = lines.flat_map { |x, y, text| ['-annotate', "+#{x}+#{y}", text] }
    magick('-size', "#{width}x#{height}", 'xc:white', '-fill', 'black',
           '-pointsize', point_size.to_s, *draws, "#{format}:-")
  end

  # Rotated JPEG with EXIF orientation 6 and GPS tag.
  def phone_photo(lines:, width: 800, height: 500)
    upright = image(lines: lines, width: width, height: height, format: 'png')
    sideways = magick('png:-',
                      '-rotate', '-90',
                      '-set', 'comment', 'Taken by Jane Example',
                      'jpeg:-',
                      stdin: upright)
    with_exif(sideways, orientation: 6)
  end

  def with_exif(jpeg, orientation:)
    entry = ->(tag, type, count, value) do
      [tag, type, count].pack('nnN') + value
    end
    ifd = ->(entries) do
      [entries.size].pack('n') + entries.join + [0].pack('N')
    end
    rationals = ->(deg, min, sec) do
      [deg, 1, min, 1, sec * 100, 100].pack('N6')
    end
    # Header (8) + IFD0 (2 + 2 x 12 + 4 = 30) puts the GPS IFD at 38, and the
    # GPS IFD (2 + 4 x 12 + 4 = 54) puts its values at 92 and 116.
    ifd0 = ifd.call([entry.call(0x0112, 3, 1, [orientation, 0].pack('nn')),
                     entry.call(0x8825, 4, 1, [38].pack('N'))])
    gps = ifd.call([entry.call(0x0001, 2, 2, "N\0\0\0".b),
                    entry.call(0x0002, 5, 3, [92].pack('N')),
                    entry.call(0x0003, 2, 2, "W\0\0\0".b),
                    entry.call(0x0004, 5, 3, [116].pack('N'))])
    tiff = "MM\0*".b + [8].pack('N') + ifd0 + gps +
           rationals.call(51, 30, 26) + rationals.call(0, 7, 39)
    app1 = "\xFF\xE1".b + [tiff.bytesize + 8].pack('n') + "Exif\0\0".b + tiff
    jpeg.byteslice(0, 2) + app1 + jpeg.byteslice(2..)
  end

  def docx(paragraphs:)
    runs = paragraphs.map do |text|
      "<w:p><w:r><w:t xml:space=\"preserve\">#{xml_escape(text)}" \
        '</w:t></w:r></w:p>'
    end.join
    extras = '<w:p><w:ins w:id="1" w:author="Jane Example"><w:r>' \
             '<w:t>Inserted words.</w:t></w:r></w:ins>' \
             '<w:del w:id="2" w:author="Jane Example"><w:r>' \
             '<w:delText>Deleted words naming Jane Example.</w:delText>' \
             '</w:r></w:del></w:p>' \
             '<w:p><w:r><w:rPr><w:vanish/></w:rPr>' \
             '<w:t>Hidden text: internal reference JX-42.</w:t></w:r></w:p>' \
             '<w:p><w:commentRangeStart w:id="0"/>' \
             '<w:r><w:t>Commented sentence.</w:t></w:r>' \
             '<w:commentRangeEnd w:id="0"/>' \
             '<w:r><w:commentReference w:id="0"/></w:r></w:p>'
    w = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'
    ooxml(
      '[Content_Types].xml' => content_types(
        '/word/document.xml' =>
          'application/vnd.openxmlformats-officedocument.wordprocessingml.' \
          'document.main+xml',
        '/word/comments.xml' =>
          'application/vnd.openxmlformats-officedocument.wordprocessingml.' \
          'comments+xml',
        '/docProps/core.xml' =>
          'application/vnd.openxmlformats-package.core-properties+xml'
      ),
      '_rels/.rels' => rels('officeDocument' => 'word/document.xml',
                            'metadata/core-properties' => 'docProps/core.xml'),
      'word/_rels/document.xml.rels' => rels('comments' => 'comments.xml'),
      'word/document.xml' =>
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' \
        "<w:document #{w}><w:body>#{runs}#{extras}</w:body></w:document>",
      'word/comments.xml' =>
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' \
        "<w:comments #{w}>" \
        '<w:comment w:id="0" w:author="Jane Example"><w:p><w:r>' \
        '<w:t>Check with Jane before release.</w:t>' \
        '</w:r></w:p></w:comment></w:comments>',
      'docProps/core.xml' => core_properties('Jane Example')
    )
  end

  def xlsx
    ooxml(
      '[Content_Types].xml' => content_types(
        '/xl/workbook.xml' =>
          'application/vnd.openxmlformats-officedocument.spreadsheetml.' \
          'sheet.main+xml',
        '/xl/worksheets/sheet1.xml' =>
          'application/vnd.openxmlformats-officedocument.spreadsheetml.' \
          'worksheet+xml',
        '/xl/worksheets/sheet2.xml' =>
          'application/vnd.openxmlformats-officedocument.spreadsheetml.' \
          'worksheet+xml',
        '/docProps/core.xml' =>
          'application/vnd.openxmlformats-package.core-properties+xml'
      ),
      '_rels/.rels' => rels('officeDocument' => 'xl/workbook.xml',
                            'metadata/core-properties' => 'docProps/core.xml'),
      'xl/workbook.xml' =>
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' \
        '<workbook ' \
        'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" ' \
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/' \
        'relationships"><sheets>' \
        '<sheet name="Summary" sheetId="1" r:id="rId1"/>' \
        '<sheet name="Staff" sheetId="2" state="hidden" r:id="rId2"/>' \
        '</sheets></workbook>',
      'xl/_rels/workbook.xml.rels' =>
        rels('worksheet' => %w[worksheets/sheet1.xml worksheets/sheet2.xml]),
      'xl/worksheets/sheet1.xml' => sheet(
        [['Year', 'Incidents'],
         ['2024', '12'],
         ['2025', '9'],
         ['Note', 'HIDDENROW Jane Example on leave']],
        hidden_rows: [4]
      ),
      'xl/worksheets/sheet2.xml' => sheet(
        [['Name', 'Role'],
         ['HIDDENSHEET Jane Example', 'Investigator'],
         ['HIDDENSHEET John Sample', 'Constable']]
      ),
      'docProps/core.xml' => core_properties('Jane Example')
    )
  end

  def ooxml(files)
    require 'zip'
    buffer = Zip::OutputStream.write_buffer do |zip|
      files.each do |name, body|
        zip.put_next_entry(name)
        zip.write(body)
      end
    end
    buffer.string
  end

  def content_types(overrides)
    parts = overrides.map do |part, type|
      %(<Override PartName="#{part}" ContentType="#{type}"/>)
    end.join
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' \
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/' \
      'content-types"><Default Extension="rels" ' \
      'ContentType="application/vnd.openxmlformats-package.' \
      'relationships+xml"/>' \
      "<Default Extension=\"xml\" ContentType=\"application/xml\"/>#{parts}" \
      '</Types>'
  end

  def rels(targets)
    n = 0
    items = targets.flat_map do |type, paths|
      Array(paths).map do |path|
        n += 1
        base = if type.start_with?('metadata/')
                 'http://schemas.openxmlformats.org/package/2006/relationships'
               else
                 'http://schemas.openxmlformats.org/officeDocument/2006/' \
                   'relationships'
               end
        %(<Relationship Id="rId#{n}" Type="#{base}/#{type}" Target="#{path}"/>)
      end
    end
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' \
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/' \
      '2006/relationships">' \
      "#{items.join}</Relationships>"
  end

  def sheet(rows, hidden_rows: [])
    data = rows.each_with_index.map do |row, r|
      cells = row.each_with_index.map do |value, c|
        %(<c r="#{('A'.ord + c).chr}#{r + 1}" t="inlineStr"><is><t>) \
          "#{xml_escape(value)}</t></is></c>"
      end.join
      hidden = hidden_rows.include?(r + 1) ? ' hidden="1"' : ''
      %(<row r="#{r + 1}"#{hidden}>#{cells}</row>)
    end.join
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' \
      '<worksheet ' \
      'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' \
      "<sheetData>#{data}</sheetData></worksheet>"
  end

  def core_properties(creator)
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' \
      '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/' \
      'package/2006/metadata/core-properties" ' \
      'xmlns:dc="http://purl.org/dc/elements/1.1/">' \
      "<dc:creator>#{xml_escape(creator)}</dc:creator>" \
      "<cp:lastModifiedBy>#{xml_escape(creator)}</cp:lastModifiedBy>" \
      '</cp:coreProperties>'
  end

  def xml_escape(text)
    text.to_s.encode(xml: :text)
  end

  def encrypted_pdf(pdf)
    Dir.mktmpdir do |dir|
      File.binwrite("#{dir}/in.pdf", pdf)
      system('pdftk', "#{dir}/in.pdf",
             'output', "#{dir}/out.pdf",
             'user_pw', 'synthetic-secret',
             exception: true)
      File.binread("#{dir}/out.pdf")
    end
  end

  # Pixel stats (0..1) for a fractional [x0, y0, x1, y1] box from top-left;
  # inset excludes edge resampling.
  def region(png, box, inset: 3)
    width, height = magick('identify', '-format', '%w %h', png).
      split.map(&:to_i)
    x0, y0, x1, y1 = box
    geometry = "#{((x1 - x0) * width).floor - (2 * inset)}x" \
               "#{((y1 - y0) * height).floor - (2 * inset)}" \
               "+#{(x0 * width).ceil + inset}+#{(y0 * height).ceil + inset}"
    max, mean, min = magick(png,
                            '-crop', geometry,
                            '+repage',
                            '-format', '%[fx:maxima] %[fx:mean] %[fx:minima]',
                            'info:').split.map(&:to_f)
    { max: max, mean: mean, min: min }
  end

  def render_pages(pdf_path, dir, dpi: 100)
    system('pdftoppm', '-cropbox', '-r', dpi.to_s, '-png',
           pdf_path, File.join(dir, 'page'),
           exception: true)
    Dir[File.join(dir, 'page-*.png')].
      sort_by { |path| path[/(\d+)\.png\z/, 1].to_i }
  end

  def pdf_text(pdf_path)
    `pdftotext -enc UTF-8 #{Shellwords.escape(pdf_path)} -`
  end

  def magick(*args, stdin: nil)
    require 'open3'
    out, err, status = Open3.capture3('magick', *args,
                                      stdin_data: stdin,
                                      binmode: true)
    raise "magick failed: #{err}" unless status.success?

    out
  end

  def page_content(page)
    parts = page.fetch(:texts, []).map do |text|
      r, g, b = text.fetch(:colour, [0, 0, 0])
      "BT #{r} #{g} #{b} rg /F1 #{text.fetch(:size, 14)} Tf " \
        "#{text[:x]} #{text[:y]} Td (#{escape(text[:text])}) Tj ET"
    end
    parts += page.fetch(:boxes, []).map do |box|
      r, g, b = box.fetch(:colour, [0, 0, 0])
      "#{r} #{g} #{b} rg #{box[:x]} #{box[:y]} #{box[:w]} #{box[:h]} re f"
    end
    parts.join("\n")
  end

  def escape(text)
    text.to_s.gsub(/[\\()]/) { |c| "\\#{c}" }
  end

  def write(objects, root:, info:)
    out = +"%PDF-1.4\n%\xE2\xE3\xCF\xD3\n".b
    offsets = objects.each_with_index.map do |body, index|
      offset = out.bytesize
      out << "#{index + 1} 0 obj\n#{body}\nendobj\n".b
      offset
    end
    xref = out.bytesize
    out << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n".b
    offsets.each { |offset| out << format("%010d 00000 n \n", offset).b }
    trailer = "/Size #{objects.size + 1} /Root #{root} 0 R"
    trailer += " /Info #{info} 0 R" if info
    out << "trailer\n<< #{trailer} >>\nstartxref\n#{xref}\n%%EOF\n".b
    out
  end
end
