module AttachmentManagement
  module Engines
    # Rasterizes PDFs and images via Poppler/ImageMagick/LibreOffice, painting
    # redaction boxes into pixels and rebuilding PDFs from page images alone.
    class Raster
      NAME = 'raster-v1'.freeze
      DPI = 150
      PREVIEW_DPI = 100
      PREVIEW_MAX = 1600
      # Pixel cap on a rendered page's longest side to bound hostile dimensions.
      MAX_SIDE = 5000
      MAX_PAGES = 500
      # Fail fast: rebuilt page images hit the 50 MB output cap around 40 pages.
      MAX_REBUILT_PAGES = 40
      # Per-page PDF wrapper overhead stripped when pdftk concatenates pages.
      PAGE_WRAPPER_BYTES = 4096
      # Max pixel brightness (0..1, inset 2px) allowed inside a verified box.
      INK_LIMIT = 0.05
      IMAGE_CODERS = {
        'image/jpeg' => 'jpeg', 'image/jpg' => 'jpeg', 'image/pjpeg' => 'jpeg',
        'image/png' => 'png', 'image/x-png' => 'png', 'image/gif' => 'gif',
        'image/bmp' => 'bmp', 'image/x-ms-bmp' => 'bmp', 'image/webp' => 'webp',
        'image/tiff' => 'tiff'
      }.freeze
      MAGICK_LIMITS = %w[-limit memory 512MiB -limit map 1GiB -limit disk 2GiB
                         -limit area 128MP -limit time 120].freeze

      attr_reader :job

      def initialize(job:)
        @job = job
      end

      def name
        NAME
      end

      def pdf_info(path)
        out = text(Command.run('pdfinfo', path, job: job, timeout: 30))
        pages = out[/^Pages:\s+(\d+)/, 1].to_i
        if pages > MAX_PAGES
          raise Unsupported.new(:too_large, _('{{count}} pages', count: pages))
        end

        {
          pages: pages,
          encrypted: out[/^Encrypted:\s+(\S+)/, 1] == 'yes',
          javascript: out[/^JavaScript:\s+(\S+)/, 1] == 'yes',
          form: out[/^Form:\s+(.+)$/, 1].to_s.strip,
          metadata_stream: out[/^Metadata Stream:\s+(\S+)/, 1] == 'yes',
          metadata: %w[Title Author Subject Keywords Creator Producer].
            to_h do |key|
              [key.downcase, out[/^#{key}:\s+(.+)$/, 1].to_s.strip]
            end.compact_blank
        }
      rescue Command::Failed => e
        if /password/i.match?(e.message)
          raise Unsupported.new(:encrypted, e.message)
        end

        raise Unsupported.new(:unreadable_pdf, e.message)
      end

      # Passing known size (in points) skips an extra pdfinfo call.
      def render_pdf_page(path, page, png, dpi: PREVIEW_DPI, size: nil)
        prefix = png.delete_suffix('.png')
        resolution = size ? dpi_for(size, dpi) : capped_dpi(path, page, dpi)
        Command.run('pdftoppm', '-cropbox', '-r', resolution,
                    '-f', page, '-l', page,
                    '-png', '-singlefile', path, prefix, job: job, timeout: 60)
        unless File.exist?(png)
          raise Unsupported.new(:unreadable_pdf, 'no page image')
        end

        png
      end

      def redact_pdf(input, boxes, output)
        info = pdf_info(input)
        raise Unsupported.new(:unreadable_pdf, 'no pages') if info[:pages].zero?
        if info[:pages] > MAX_REBUILT_PAGES
          raise Command::Failed, _('{{count}} pages is too many to rebuild ' \
                                   '(the most is {{max}})',
                                   count: info[:pages], max: MAX_REBUILT_PAGES)
        end

        sizes = page_sizes(input, info[:pages])
        Dir.mktmpdir('raster-pdf', File.dirname(output)) do |dir|
          built = 0
          page_pdfs = (1..info[:pages]).map do |page|
            page_pdf = rebuild_page(input, page, dir, sizes, boxes)
            built += File.size(page_pdf) - PAGE_WRAPPER_BYTES
            if built > AttachmentManagement.max_bytes
              raise Command::Failed,
                    _('the rebuilt PDF would be over {{size}} MB ' \
                      '({{page}} of {{pages}} pages)',
                      size: AttachmentManagement.max_bytes / 1.megabyte,
                      page: page,
                      pages: info[:pages])
            end
            page_pdf
          end
          Command.run('pdftk', *page_pdfs, 'cat', 'output', output,
                      job: job, timeout: 300)

          report = inspect_pdf(output)
          report[:boxes] = boxes.values.sum(&:size)
          report[:boxes_verified] = verify_pdf_boxes(output, boxes, dir,
                                                     report[:page_sizes])
          report[:source] = { pages: info[:pages],
                              text_characters: text_characters(input),
                              page_sizes: sizes }
          check_raster_pdf!(report, info[:pages], sizes)
          report.merge(dpi: DPI, engine: NAME)
        end
      end

      def inspect_pdf(path)
        info = pdf_info(path)
        fonts = text(Command.run('pdffonts', path, job: job, timeout: 60)).
          lines.drop(2).size
        images = text(Command.run('pdfimages', '-list', path,
                                  job: job, timeout: 60)).
          lines.drop(2).map { |line| line.split.first.to_i }.tally
        embedded = text(
          Command.run('pdfdetach', '-list', path, job: job, timeout: 30)
        )[/(\d+) embedded files?/, 1].to_i
        {
          pages: info[:pages],
          page_sizes: page_sizes(path, info[:pages]),
          text_characters: text_characters(path),
          fonts: fonts,
          images_per_page:
            (1..info[:pages]).map { |page| images.fetch(page, 0) },
          embedded_files: embedded,
          javascript: info[:javascript],
          form: info[:form],
          metadata: info[:metadata],
          metadata_stream: info[:metadata_stream],
          annotations: AttachmentManagement.read_output(path, job: job).
            scan(%r{/Type\s*/Annot\b}).size
        }
      end

      def text_characters(path)
        text(
          Command.run('pdftotext', '-enc', 'UTF-8', path, '-',
                      job: job, timeout: 120)
        ).gsub(/\s+/, '').size
      end

      def coder_for(content_type)
        IMAGE_CODERS[content_type]
      end

      def image_info(path, coder)
        frames = text(magick_identify('-format', "%w %h\n",
                                      "#{coder}:#{path}")).lines
        width, height =
          text(magick("#{coder}:#{path}[0]", '-auto-orient',
                      '-format', '%w %h', 'info:')).split.map(&:to_i)
        { coder: coder, width: width, height: height, frames: frames.size }
      rescue Command::Failed => e
        raise Unsupported.new(:unreadable_image, e.message)
      end

      def render_image(path, coder, png)
        magick("#{coder}:#{path}[0]", '-auto-orient', '-strip', '-resize',
               "#{PREVIEW_MAX}x#{PREVIEW_MAX}>", "png:#{png}")
        png
      rescue Command::Failed => e
        raise Unsupported.new(:unreadable_image, e.message)
      end

      def redact_image(input, coder, boxes, output)
        info = image_info(input, coder)
        if info[:frames] > 1 && coder != 'gif'
          raise Unsupported.new(:multi_page_image,
                                _('{{count}} pages', count: info[:frames]))
        end

        metadata_before = image_metadata(input, coder)
        paint(input, coder, boxes, output: output, coalesce: coder == 'gif')
        after = image_info(output, coder)
        unless [after[:width], after[:height]] == [info[:width], info[:height]]
          raise Command::Failed, 'the redacted image changed size'
        end

        flat = File.join(File.dirname(output), 'verify.png')
        magick("#{coder}:#{output}", '-coalesce', "png:#{flat}")
        frames = coder == 'gif' ? Dir[flat.sub('.png', '*.png')] : [flat]
        verified = frames.sum { |frame| verify_boxes(frame, boxes) }
        expected = boxes.size * frames.size
        unless verified == expected
          raise Command::Failed, 'a box was not black in the output'
        end

        metadata_after = image_metadata(output, coder)
        raise Command::Failed, 'image metadata survived' if metadata_after.any?

        { width: info[:width],
          height: info[:height],
          frames: info[:frames],
          boxes: boxes.size,
          boxes_verified: verified,
          metadata_removed: metadata_before,
          engine: NAME }
      end

      # LibreOffice picks its import filter from the file extension.
      def convert_to_pdf(input, extension, output, filter: nil)
        Dir.mktmpdir('office', File.dirname(output)) do |dir|
          source = File.join(dir, "source.#{extension}")
          FileUtils.cp(input, source)
          Command.run('soffice', '--headless', '--norestore', '--nolockcheck',
                      '--nodefault',
                      "-env:UserInstallation=file://#{dir}/profile",
                      '--convert-to', filter ? "pdf:#{filter}" : 'pdf',
                      '--outdir', dir, source,
                      job: job, timeout: 180)
          converted = File.join(dir, 'source.pdf')
          unless File.exist?(converted)
            raise Unsupported.new(:conversion_failed,
                                  'LibreOffice wrote no PDF')
          end

          AttachmentManagement.copy_output(converted, job: job, to: output)
        end
        inspect_pdf(output).merge(engine: 'libreoffice')
      end

      # Displayed page sizes in points (pdfinfo crop box adjusted for rotation).
      def page_sizes(path, pages)
        out = text(Command.run('pdfinfo', '-f', 1, '-l', pages, path,
                               job: job, timeout: 60))
        (1..pages).map do |page|
          size = out.match(/^Page\s+#{page} size:\s+([\d.]+) x ([\d.]+)/) or
            raise Unsupported.new(:unreadable_pdf, "no size for page #{page}")
          width, height = size.captures.map(&:to_f)
          if (out[/^Page\s+#{page} rot:\s+(\d+)/, 1].to_i / 90).odd?
            [height, width]
          else
            [width, height]
          end
        end
      end

      def capped_dpi(path, page, dpi)
        out = text(Command.run('pdfinfo', '-f', page, '-l', page, path,
                               job: job, timeout: 30))
        size = out.match(/^Page\s+#{page} size:\s+([\d.]+) x ([\d.]+)/)
        return dpi unless size

        dpi_for([size[1].to_f, size[2].to_f], dpi)
      end

      def dpi_for(size, dpi)
        [[dpi, (MAX_SIDE * 72 / size.max).floor].min, 10].max
      end

      private

      def rebuild_page(input, page, dir, sizes, boxes)
        png = render_pdf_page(input, page,
                              File.join(dir, "page-#{page}.png"),
                              dpi: DPI, size: sizes[page - 1])
        paint(png, 'png', boxes.fetch(page, []))
        page_pdf = File.join(dir, "page-#{page}.pdf")
        # Match rendered pixel density so physical page size stays unchanged.
        magick("png:#{png}", '-background', 'white',
               '-alpha', 'remove', '-alpha', 'off', '-strip',
               '-density', density_for(png, sizes[page - 1]),
               '-units', 'PixelsPerInch', '-compress', 'zip',
               "pdf:#{page_pdf}")
        FileUtils.rm_f(png)
        page_pdf
      end

      def paint(path, coder, boxes, output: path, coalesce: false)
        return if boxes.empty? && output == path

        width, height =
          text(magick("#{coder}:#{path}[0]", '-auto-orient',
                      '-format', '%w %h', 'info:')).split.map(&:to_i)
        draws = pixel_boxes(boxes, width, height).flat_map do |x0, y0, x1, y1|
          ['-draw', "rectangle #{x0},#{y0} #{x1},#{y1}"]
        end
        options = coalesce ? ['-coalesce'] : []
        options += ['-auto-orient', '+antialias', '-fill', 'black',
                    '-stroke', 'none', *draws, '-strip']
        options += ['-quality', '92'] if coder == 'jpeg'
        options += ['-layers', 'optimize'] if coalesce
        magick("#{coder}:#{path}", *options, "#{coder}:#{output}")
      end

      # Rounded outwards, so a box never covers less than was drawn.
      def pixel_boxes(boxes, width, height)
        boxes.map do |x0, y0, x1, y1|
          [(x0 * width).floor,
           (y0 * height).floor,
           [(x1 * width).ceil, width - 1].min,
           [(y1 * height).ceil, height - 1].min]
        end
      end

      def density_for(png, (width, height))
        pixels_w, pixels_h =
          text(magick_identify('-format', '%w %h', "png:#{png}")).
          split.map(&:to_i)
        format('%.6fx%.6f', pixels_w * 72.0 / width, pixels_h * 72.0 / height)
      end

      def verify_pdf_boxes(pdf, boxes, dir, sizes)
        boxes.sum do |page, page_boxes|
          png = render_pdf_page(pdf, page,
                                File.join(dir, "verify-#{page}.png"),
                                dpi: DPI, size: sizes[page - 1])
          verify_boxes(png, page_boxes)
        end
      end

      def verify_boxes(png, boxes)
        width, height =
          text(magick_identify('-format', '%w %h', "png:#{png}")).
          split.map(&:to_i)
        pixel_boxes(boxes, width, height).count do |x0, y0, x1, y1|
          inset_w = x1 - x0 - 4
          inset_h = y1 - y0 - 4
          next true if inset_w <= 0 || inset_h <= 0

          lightest = text(magick("png:#{png}", '-crop',
                                 "#{inset_w}x#{inset_h}+#{x0 + 2}+#{y0 + 2}",
                                 '+repage', '-format', '%[fx:maxima]',
                                 'info:')).to_f
          lightest <= INK_LIMIT
        end
      end

      def check_raster_pdf!(report, pages, sizes)
        problems = []
        report[:page_sizes].zip(sizes).
          each_with_index do |((width, height), (want_w, want_h)), index|
            next if (width - want_w).abs <= 0.5 && (height - want_h).abs <= 0.5

            problems << "page #{index + 1} is #{width} x #{height} pt, " \
                        "not #{want_w} x #{want_h}"
          end
        unless report[:pages] == pages
          problems << "#{report[:pages]} pages, expected #{pages}"
        end
        unless report[:text_characters].zero?
          problems << "#{report[:text_characters]} characters of text left"
        end
        problems << "#{report[:fonts]} fonts left" unless report[:fonts].zero?
        unless report[:images_per_page].all?(1)
          problems << 'pages are not one image each'
        end
        problems << 'embedded files left' unless report[:embedded_files].zero?
        problems << 'scripts left' if report[:javascript]
        problems << 'annotations left' unless report[:annotations].zero?
        unless report[:boxes_verified] == report[:boxes]
          problems << 'a box was not black in the output'
        end
        raise Command::Failed, "output check failed: #{problems.join('; ')}" if
          problems.any?
      end

      # Return metadata field names only; values may contain redacted data.
      def image_metadata(path, coder)
        exif = text(magick_identify('-format', '%[EXIF:*]',
                                    "#{coder}:#{path}[0]")).
          lines.filter_map do |line|
            line.split('=', 2).first.to_s.sub(/\Aexif:/i, '').strip.presence
          end
        iptc = text(magick_identify('-format', '%[IPTC:*]',
                                    "#{coder}:#{path}[0]")).strip
        comment = text(magick_identify('-format', '%c',
                                       "#{coder}:#{path}[0]")).strip
        names = exif.uniq.map { |name| "EXIF #{name}" }
        names << 'IPTC' if iptc.present?
        names << 'comment' if comment.present?
        names
      rescue Command::Failed
        []
      end

      def magick(*args)
        Command.run('magick', *MAGICK_LIMITS, *args, job: job, timeout: 180)
      end

      def magick_identify(*args)
        Command.run('magick', 'identify', *MAGICK_LIMITS, *args,
                    job: job, timeout: 60)
      end

      def text(bytes)
        bytes.to_s.dup.force_encoding('UTF-8').scrub
      end
    end
  end
end
