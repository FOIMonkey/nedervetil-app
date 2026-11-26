module Disclosures
  # Extracts visible PDF words by checking each pdftotext box for contrast in a
  # greyscale poppler render (never ImageMagick). Low-contrast and off-cropbox
  # words are excluded and counted as hidden.
  module PDFText
    # lines: rows of { text:, box: [x0, y0, x1, y1] } as page fractions, or nil
    # if the page could not be measured/rendered.
    Page = Struct.new(:number, :text, :hidden, :lines, keyword_init: true)
    # Min pixel contrast (0-255) for a word box to count as visible.
    MIN_CONTRAST = 24
    DPI = 100
    # 8-bit greyscale render, capped at max side squared plus header.
    MAX_PGM = (AttachmentManagement::Engines::Raster::MAX_SIDE**2) + 1.kilobyte
    BAND = 32

    module_function

    # job: AlaveteliSandbox job holding path and dir, or nil.
    def pages(path, last, dir, job:)
      document = bbox_layout(path, last, '-cropbox', job: job)
      # Words outside cropbox (present in mediabox) count as hidden.
      whole = bbox_layout(path, last, job: job).xpath('//page').
        map { |page| page.xpath('.//word').size }
      document.xpath('//page').first(last).each_with_index.map do |page, index|
        number = index + 1
        words = page.xpath('.//line').map do |line|
          line.xpath('./word').map { |word| word_of(word) }
        end
        result = if words.flatten(1).empty?
                   Page.new(number: number, text: '', hidden: 0, lines: [])
                 elsif (grey = render_grey(path, number, dir, job: job))
                   width, height = page_size(page, grey)
                   visible(number, width, height, words, grey)
                 else
                   # Couldn't render, so no word counts as seen: fail closed.
                   Page.new(number: number,
                            text: '',
                            hidden: words.flatten(1).size)
                 end
        result.hidden += [whole[index].to_i - words.flatten(1).size, 0].max
        result
      end
    end

    def bbox_layout(path, last, *options, job:)
      layout = AttachmentManagement::Command.run(
        'pdftotext', '-bbox-layout', *options, '-enc', 'UTF-8',
        '-f', 1, '-l', last, path, '-', job: job, timeout: 120
      )
      Nokogiri::XML(layout.to_s.dup.force_encoding('UTF-8').scrub, &:nonet).
        tap(&:remove_namespaces!)
    end

    def word_of(node)
      { text: node.text,
        x0: node['xMin'].to_f,
        y0: node['yMin'].to_f,
        x1: node['xMax'].to_f,
        y1: node['yMax'].to_f }
    end

    # pdftotext reports rotated word boxes as shown, but page size pre-rotation.
    def page_size(page, grey)
      width = page['width'].to_f
      height = page['height'].to_f
      if (width > height) == (grey[:width] > grey[:height])
        [width, height]
      else
        [height, width]
      end
    end

    def visible(number, width, height, lines, grey)
      words = lines.flatten(1)
      kept = words
      measured = width.positive? && height.positive?
      if measured
        boxes = words.map { |word| pixel_box(word, width, height, grey) }
        covers = overlaps(boxes)
        kept = words.select.with_index do |_word, index|
          shows?(boxes[index][:inner], covers[index], grey)
        end
      end
      shown = rows(kept)
      Page.new(number: number,
               text: shown.map { |row| layout_line(row) }.join("\n"),
               hidden: words.size - kept.size,
               lines: (placed(shown, width, height) if measured))
    end

    def placed(rows, width, height)
      rows.map do |row|
        row.map do |word|
          { text: word[:text],
            box: [word[:x0] / width, word[:y0] / height,
                  word[:x1] / width, word[:y1] / height] }
        end
      end
    end

    # Rebuild rows by position: pdftotext splits table columns into blocks.
    def rows(words)
      grouped = words.
        sort_by { |word| [(word[:y0] + word[:y1]) / 2, word[:x0]] }.
        each_with_object([]) do |word, rows|
          middle = (word[:y0] + word[:y1]) / 2
          row = rows.last
          if row && (middle - row[:middle]).abs <=
                    [(word[:y1] - word[:y0]) / 2, 1].max
            row[:words] << word
          else
            rows << { middle: middle, words: [word] }
          end
        end
      grouped.map { |row| row[:words].sort_by { |word| word[:x0] } }
    end

    # Wide gaps become several spaces, as pdftotext -layout would give.
    def layout_line(words)
      char = words.sum { |word|
        (word[:x1] - word[:x0]) / [word[:text].length, 1].max
      } / words.size
      char = 4.0 if char <= 0
      words.each_with_index.map do |word, index|
        next word[:text] if index.zero?

        before = words[index - 1][:text]
        # A box is wider than its label, but it's one thing in the sentence.
        if before == Reader::REDACTED || word[:text] == Reader::REDACTED
          next word[:text] if word[:text].match?(/\A[,.;:!?)]/)

          next " #{word[:text]}"
        end

        gap = word[:x0] - words[index - 1][:x1]
        spaces = gap > char * 2 ? (gap / char).round.clamp(3, 40) : 1
        (' ' * spaces) + word[:text]
      end.join
    end

    # Inclusive [x0, y0, x1, y1]; :inner insets 1px against flush boxes.
    def pixel_box(word, width, height, grey)
      x0, x1, inner_x0, inner_x1 = span(
        word[:x0], word[:x1], width, grey[:width]
      )
      y0, y1, inner_y0, inner_y1 = span(
        word[:y0], word[:y1], height, grey[:height]
      )
      { outer: [x0, y0, x1, y1],
        inner: [inner_x0, inner_y0, inner_x1, inner_y1] }
    end

    def span(from, to, size, pixels)
      start = from / size * pixels
      stop = to / size * pixels
      inner = [start.ceil + 1, stop.floor - 2]
      inner = [start.ceil, stop.floor - 1] if inner[1] < inner[0]
      inner = [((start + stop) / 2).floor] * 2 if inner[1] < inner[0]
      [start.floor, stop.ceil - 1, *inner].
        map { |value| value.clamp(0, pixels - 1) }
    end

    # Exclude other words' outer boxes overlapping :inner so white labels (e.g.
    # "s.40(2)") on a redaction box don't make covered words look visible.
    def overlaps(boxes)
      bands = Hash.new { |hash, band| hash[band] = [] }
      boxes.each_with_index do |box, index|
        ((box[:outer][1] / BAND)..(box[:outer][3] / BAND)).
          each { |band| bands[band] << index }
      end
      boxes.each_with_index.map do |box, index|
        x0, y0, x1, y1 = box[:inner]
        ((y0 / BAND)..(y1 / BAND)).flat_map { |band| bands[band] }.uniq.
          filter_map do |other|
            next if other == index

            ox0, oy0, ox1, oy1 = boxes[other][:outer]
            if ox0 <= x1 && ox1 >= x0 && oy0 <= y1 && oy1 >= y0
              boxes[other][:outer]
            end
          end
      end
    end

    # Nothing left to look at counts as not visible.
    def shows?(box, covers, grey)
      x0, y0, x1, y1 = box
      darkest = 255
      lightest = 0
      (y0..y1).each do |y|
        row = y * grey[:width]
        (x0..x1).each do |x|
          next if covers.any? do |cx0, cy0, cx1, cy1|
            x.between?(cx0, cx1) && y.between?(cy0, cy1)
          end

          value = grey[:pixels].getbyte(row + x)
          darkest = value if value < darkest
          lightest = value if value > lightest
        end
        return true if lightest - darkest >= MIN_CONTRAST
      end
      false
    end

    def render_grey(path, number, dir, job:)
      prefix = File.join(dir, "grey-#{number}")
      dpi = Disclosures.engine(job: job).capped_dpi(path, number, DPI)
      AttachmentManagement::Command.run(
        'pdftoppm', '-cropbox', '-gray', '-r', dpi, '-f', number, '-l', number,
        '-singlefile', path, prefix, job: job, timeout: 60
      )
      data = AttachmentManagement.read_output("#{prefix}.pgm",
                                              job: job, max: MAX_PGM)
      header = data.match(/\AP5\s+(\d+)\s+(\d+)\s+(\d+)\s/n) or return nil
      width = header[1].to_i
      height = header[2].to_i
      unless header[3].to_i < 256 && width.positive? && height.positive?
        return nil
      end

      pixels = data.byteslice(header.end(0), width * height)
      return nil unless pixels && pixels.bytesize == width * height

      { width: width, height: height, pixels: pixels }
    rescue AttachmentManagement::Command::Failed, Errno::ENOENT
      nil
    ensure
      FileUtils.rm_f("#{prefix}.pgm") if prefix
    end
  end
end
