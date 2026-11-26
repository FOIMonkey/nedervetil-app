# frozen_string_literal: true

module PDFRedactor
  ##
  # Reads pages that are only pictures with tesseract, and swaps pages for
  # pictures of themselves. Every program runs as a sandbox step. Unlike
  # Disclosures::Ocr, it reads a page as it lies, turned or not.
  module Ocr
    DPI = 200
    # The picture that replaces a page.
    RASTER_DPI = 150
    # tesseract is the slow step, so pages are shared between a few jobs.
    JOBS = 4
    TESSERACT_ENV = { 'OMP_THREAD_LIMIT' => '1' }.freeze
    Word = Struct.new(:text, :x0, :y0, :x1, :y1, :line)

    module_function

    # Accents, case and the usual OCR confusions folded away: "ü" read as
    # "ii", and, for a rule with no digits, "0" for "o" and "1" for "l".
    def fold(s, letters: false)
      f = s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, '').downcase
      f = f.gsub(/[^\p{Alnum}@.\-]/, '').gsub('ii', 'u')
      letters ? f.tr('01|', 'oll') : f
    end

    # A rule such as "Council" inside an OCR word such as "Counci1lors".
    def near_substring?(word, want)
      limit = want.size / 5
      (0..(word.size - want.size)).any? do |i|
        [want.size - 1, want.size, want.size + 1].any? do |len|
          len.positive? && i + len <= word.size &&
            distance(word[i, len], want) <= limit
        end
      end
    end

    def distance(a, b)
      prev = (0..b.size).to_a
      a.each_char.with_index(1) do |ca, i|
        cur = [i]
        b.each_char.with_index(1) do |cb, j|
          swap = prev[j - 1] + (ca == cb ? 0 : 1)
          cur << [prev[j] + 1, cur[j - 1] + 1, swap].min
        end
        prev = cur
      end
      prev.last
    end

    def available?
      backend = PDFRedactor.backend
      %w[pdftoppm tesseract magick].all? do |program|
        backend.program_path(program)
      end
    rescue backend::ToolError
      false
    end

    # Words with their pixel boxes for each page number, or nil for a page
    # that couldn't be read.
    def read_pages(pdf, numbers)
      return [] if numbers.empty?

      parts = numbers.each_slice((numbers.size + JOBS - 1) / JOBS)
      read = parts.map do |part|
        Thread.new do
          PDFRedactor.backend.job(input: pdf, input_name: 'input.pdf') do |job|
            part.to_h { |n| [n, page_words(job, n)] }
          end
        rescue PDFRedactor.backend::ToolError
          {}
        end
      end
      found = read.map(&:value).reduce({}, :merge)
      numbers.map { |n| found[n] }
    end

    def page_words(job, number)
      job.run('pdftoppm', '-r', DPI.to_s, '-gray', '-png', '-f', number.to_s,
              '-l', number.to_s, '-singlefile', job.input, job.scratch('page'))
      words(job.run('tesseract', job.scratch('page.png'), 'stdout', 'tsv',
                    env: TESSERACT_ENV).stdout)
    rescue PDFRedactor.backend::ToolError
      nil
    end

    # Words with their pixel boxes, in tesseract's reading order.
    def words(tsv)
      tsv.force_encoding('UTF-8').scrub('').lines.drop(1).filter_map do |l|
        f = l.chomp.split("\t")
        next unless f[0] == '5' && f[11].to_s.strip != '' && f[10].to_f >= 0

        x, y, w, h = f[6..9].map(&:to_i)
        Word.new(f[11].strip, x, y, x + w, y + h, f[1..4].join('.'))
      end
    end

    # Pixel position in pdftoppm's picture of the page -> page space.
    def to_page(attrs, doc)
      box = attrs['CropBox'] || attrs['MediaBox'] || [0, 0, 612, 792]
      box = box.map { |v| doc.resolve(v).to_f }
      bx0 = box[0]
      by0 = box[1]
      bx1 = box[2]
      by1 = box[3]
      bx0, bx1 = bx1, bx0 if bx0 > bx1
      by0, by1 = by1, by0 if by0 > by1
      s = DPI / 72.0
      wu = (bx1 - bx0) * s
      hu = (by1 - by0) * s
      rot = attrs['Rotate'].to_i % 360
      ->(px, py) do
        u, v = case rot
               when 90 then [py, hu - px]
               when 180 then [wu - px, hu - py]
               when 270 then [wu - py, px]
               else [px, py]
               end
        [bx0 + (u / s), by1 - (v / s)]
      end
    end

    # Swaps each page in pages for a picture of itself, as drawn with the
    # boxes, so no pixel under a box is left in the file. Annotations aren't
    # drawn, as they would go over the boxes. The new page has no text layer:
    # like a scan, it can only be read with OCR. Returns the new file.
    def rasterize(pdf, pages)
      PDFRedactor.backend.job(input: pdf, input_name: 'input.pdf') do |job|
        pages.each do |n|
          job.run('pdftoppm', '-hide-annotations', '-r', RASTER_DPI.to_s,
                  '-gray', '-jpeg', '-jpegopt', 'quality=80', '-f', n.to_s,
                  '-l', n.to_s, '-singlefile', job.input, job.scratch("p#{n}"))
          job.run('magick', job.scratch("p#{n}.jpg"), '-units',
                  'PixelsPerInch', '-density', RASTER_DPI.to_s, '-compress',
                  'JPEG', '-quality', '80', job.scratch("p#{n}.pdf"))
        end
        job.run('qpdf', '--warning-exit-0', job.input, '--pages',
                *page_ranges(job, pages), '--', '-', stdout: MAX_BYTES).stdout
      end
    end

    # qpdf --pages arguments: the file's own pages, with each page in pages
    # taken from its picture instead.
    def page_ranges(job, pages)
      total = job.run('qpdf', '--show-npages', job.input).stdout.to_i
      args = []
      at = 1
      pages.each do |n|
        args.push(job.input, "#{at}-#{n - 1}") if n > at
        args.push(job.scratch("p#{n}.pdf"), '1')
        at = n + 1
      end
      args.push(job.input, "#{at}-#{total}") if at <= total
      args
    end
  end
end
