module Disclosures
  class Renderer
    # Renders each PDF page as a PNG and extracts searchable text.
    class PDF < Kind
      def initialize(document, format, outcome)
        super
        @flags = {}
      end

      private

      def pages(path, dir)
        unless raster?
          outcome.findings.concat(pdf_findings(path, dir))
          hidden_in_file(Inspector.pdf_hidden_text(path, job: job))
          rule_check(path)
        end
        render_pdf(path, dir)
      end

      def render_pdf(path, dir)
        total = engine.pdf_info(path)[:pages]
        if total.zero?
          raise AttachmentManagement::Unsupported.new(:unreadable_pdf,
                                                      'no pages')
        end

        outcome.page_count = total
        shown = [total, Disclosures.render_max_pages].min
        if total > shown
          outcome.notes['pages_not_shown'] = total - shown
          outcome.findings << "Only the first #{shown} of #{total} pages are " \
                              'shown and checked here.'
        end
        texts = if raster?
                  {}
                else
                  PDFText.pages(path, shown, dir, job: job).index_by(&:number)
                end
        @flags = flags(path, total) unless raster?
        (1..shown).each do |number|
          render_page(path, number, dir, texts)
        end
      rescue AttachmentManagement::Unsupported => e
        raise unless e.reason == :too_large

        outcome.notes['no_preview'] = 'too_large'
        outcome.findings << 'This PDF is too long to show or check here ' \
                            '(over 500 pages).'
      end

      def render_page(path, number, dir, texts)
        png = engine.render_pdf_page(path, number,
                                     File.join(dir, "page-#{number}.png"))
        text, source = page_text(texts[number], path, number, dir)
        add_image_page(number, "Page #{number}", png, text, source,
                       words: own_words(texts[number], number, source),
                       pictures: @flags[number] == ['pictures'])
        thumbnail(png, dir) if number == 1
      end

      def page_text(found, path, number, dir)
        return raster_page_text(path, number, dir) if raster?

        if found
          outcome.hidden_text << number if found.hidden.positive?
          if found.text.strip.length >= MIN_TEXT
            read_flagged(number, path, dir)
            return [found.text, 'pdftotext']
          end
        end

        scanned = ocr(number) { Ocr.pdf_page(path, number, dir, job: job) }
        return [scanned, 'ocr'] if scanned.present?

        text = found&.text.to_s
        [text, text.strip.empty? ? 'none' : 'pdftotext']
      end

      def raster_page_text(path, number, dir)
        read = false
        scanned = ocr(number) do
          Ocr.pdf_page(path, number, dir, job: job).
            tap { |text| read = !text.nil? }
        end
        unless read || outcome.ocr_skipped.include?(number)
          outcome.unread << number
        end
        scanned.present? ? [scanned, 'ocr'] : ['', 'none']
      end

      def own_words(found, number, source)
        return unless format == 'pdf' && source == 'pdftotext'
        return unless found&.lines &&
                      found.text.strip.length >= MIN_TEXT
        return unless [nil, ['pictures']].include?(@flags[number])

        map = AttachmentManagement::WordMap.of(
          found.lines.each_with_index.flat_map do |line, index|
            line.map { |word| word.merge(line: index.to_s) }
          end
        )
        map[:words] if map[:state] == 'ready'
      end

      def flags(path, total)
        pdf = AttachmentManagement.read_output(path, job: job,
                                                     max: Disclosures.max_bytes)
        PDFRedactor::Survey.pages(pdf).
          each_with_object({}) do |page, found|
            reasons = []
            reasons << 'pictures' if page['picture_share'] >= PICTURE_SHARE
            glyphs = page['visible'] + page['unmapped']
            if page['unmapped'] >= UNMAPPED_GLYPHS &&
               page['unmapped'] >= UNMAPPED_SHARE * glyphs
              reasons << 'glyphs'
            end
            found[page['number']] = reasons if reasons.any?
          end
      rescue PDFRedactor::Error, AttachmentManagement::Command::Failed => e
        Rails.logger.warn("Disclosures::Renderer document #{document.id}: " \
                          "page survey failed: #{e.message}")
        (1..total).to_h { |number| [number, ['unsurveyed']] }
      end

      def read_flagged(number, path, dir)
        reasons = @flags[number] or return

        read = false
        scanned = ocr(number) do
          Ocr.pdf_page(path, number, dir, job: job).
            tap { |text| read = !text.nil? }
        end
        if read
          outcome.flagged_text[number] = scanned.to_s
          outcome.flagged_read[number] = reasons
        elsif !outcome.ocr_skipped.include?(number)
          outcome.flagged_unread << { 'page' => number, 'reasons' => reasons }
        end
      end

      def metadata_findings(report, path)
        properties = report[:metadata].
          slice('author', 'creator', 'title', 'subject', 'keywords')
        xmp = pdf_xmp(path) if report[:metadata_stream]
        unread = report[:metadata_stream] && xmp.nil?
        user = document.requester
        names = ->(text) { !user || Checks.names?(user, text) }
        findings = properties.filter_map do |key, value|
          next unless names.call(value)

          "PDF properties: #{key.capitalize} “#{value.truncate(80)}”"
        end
        if unread || (report[:metadata_stream] && names.call(xmp))
          findings << 'An XMP metadata stream (it may name people)'
        end
        findings
      end

      def pdf_xmp(path)
        AttachmentManagement::Command.run('pdfinfo', '-meta', path,
                                          job: job, timeout: 60).
          to_s.dup.force_encoding('UTF-8').scrub
      rescue AttachmentManagement::Command::Failed
        nil
      end

      def pdf_findings(path, dir)
        report = engine.inspect_pdf(path)
        findings = metadata_findings(report, path)
        findings << 'JavaScript' if report[:javascript]
        if report[:form].present? && report[:form] != 'none'
          findings << "Form fields (#{report[:form]})"
        end
        if report[:embedded_files].positive?
          findings << "#{report[:embedded_files]} embedded " \
                      "#{'file'.pluralize(report[:embedded_files])}"
        end
        findings + Inspector.pdf(path, dir, job: job)
      rescue AttachmentManagement::Unsupported
        []
      end

      def hidden_in_file(found)
        return if found.empty?

        outcome.findings.concat(found)
        outcome.hidden_in_file = true
      end

      def raster?
        attachment.rasterized?
      end

      def engine
        Disclosures.engine(job: job)
      end
    end
  end
end
