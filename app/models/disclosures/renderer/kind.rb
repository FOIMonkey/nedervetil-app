module Disclosures
  class Renderer
    # Base renderer building disclosure_pages and thumbnail on a Document.
    class Kind
      def initialize(document, format, outcome)
        @document = document
        @attachment = document.foi_attachment
        @format = format
        @outcome = outcome
      end

      # office_read: OfficePackage::Isolated read for #office_sections.
      def render(job, office_read = nil)
        @job = job
        @office_read = office_read
        pages(job.input, job.scratch)
      end

      # OfficePackage::Isolated sections this renderer needs in one pass.
      def office_sections
        []
      end

      private

      attr_reader :document, :attachment, :format, :job, :outcome,
                  :office_read

      def findings_sections(ooxml)
        return [] unless ooxml
        unless RuleCheck::FORMATS.include?(format) &&
               RuleCheck.rules_for(document).any?
          return ['hidden']
        end

        %w[hidden strings]
      end

      def office_findings(path, read = office_read,
                          ooxml: Formats.ooxml?("file#{safe_extension}"))
        if ooxml
          HiddenRisk.findings(path, document, read: read).
            each { |finding| scored(finding) }
        else
          outcome.findings << Inspector::UNLISTED
        end
        rule_check(path, read)
      end

      def rule_check(path, read = nil)
        return unless RuleCheck::FORMATS.include?(format)

        rules = RuleCheck.rules_for(document)
        outcome.notes['rules_read'] = rules.map(&:id).sort
        return unless RuleCheck.found?(document, File.binread(path),
                                       format: format, rules: rules,
                                       read: read)

        outcome.notes['rule_matches'] = true
      end

      def scored(finding)
        outcome.findings << finding.label
        outcome.risky << finding.label if finding.high?
      end

      def add_image_page(number, label, png, text, source, words: nil,
                         pictures: false)
        width, height = magick_identify('-format', '%w %h', "png:#{png}").
          split.map(&:to_i)
        page = document.pages.create!(number: number,
                                      label: label,
                                      kind: 'image',
                                      width: width,
                                      height: height,
                                      text: masked(number, text),
                                      text_source: source)
        if words
          page.create_words!(words: PageWords.pack(words), pictures: pictures)
        end
        bytes = AttachmentManagement.read_output(png, job: job, max: MAX_PNG)
        page.image.attach(io: StringIO.new(bytes),
                          filename: "page-#{number}.png",
                          content_type: 'image/png')
      end

      def add_text_page(number, label, kind, text, source, checked: text,
                        **attributes)
        document.pages.create!(number: number,
                               label: label,
                               kind: kind,
                               text: masked(number, text, checked),
                               text_source: source,
                               **attributes)
      end

      def masked(number, text, checked = text)
        raw = Masking.clean(text)
        seen = checked.equal?(text) ? raw : Masking.clean(checked)
        outcome.always_removed << number if Masking.always_removed?(seen)
        check_text_rules(seen)
        clean = raw.first(MAX_PAGE_TEXT).gsub(
          XED_EMAIL,
          AlaveteliTextMasker::DEFAULT_TEXT_MASKS.
            dig(:email_address, :replacement)
        )
        result = Masking.apply(clean, document)
        outcome.masked << number if result != clean
        masked_on_page(number)
        result
      end

      def masked_on_page(number)
        shown = outcome.flagged_text[number] or return

        shown = Masking.clean(shown).first(MAX_PAGE_TEXT)
        outcome.always_removed << number if Masking.always_removed?(shown)
        check_text_rules(shown)
        return if Masking.apply(shown, document) == shown

        outcome.masked << number
      end

      def check_text_rules(text)
        return if outcome.notes['rule_matches']

        rules = (@rules_for_document ||= RuleCheck.rules_for(document))
        return if rules.empty?

        outcome.notes['rule_matches'] = true if RuleCheck.matched?(rules, text)
      rescue RuleCheck::Unreadable
        outcome.notes['rule_matches'] = true
      end

      def thumbnail(png, dir)
        thumb = File.join(dir, 'thumbnail.png')
        AttachmentManagement::Command.run(
          'magick', *MAGICK_LIMITS, "png:#{png}", '-thumbnail', THUMBNAIL,
          '-strip', "png:#{thumb}", job: job, timeout: 60
        )
        bytes = AttachmentManagement.read_output(thumb, job: job, max: MAX_PNG)
        document.thumbnail.attach(io: StringIO.new(bytes),
                                  filename: 'thumbnail.png',
                                  content_type: 'image/png')
      end

      def ocr(number)
        return nil unless Disclosures.ocr?

        if outcome.ocr_used >= Disclosures.ocr_max_pages
          outcome.ocr_skipped << number
          return nil
        end
        outcome.ocr_used += 1
        text = yield
        text.to_s.strip.length >= 10 ? text : nil
      end

      def safe_extension
        @safe_extension ||= Formats.safe_extension(attachment.filename,
                                                   attachment.content_type)
      end

      def magick_identify(*args)
        AttachmentManagement::Command.run(
          'magick', 'identify', *MAGICK_LIMITS, *args, job: job, timeout: 60
        ).to_s.dup.force_encoding('UTF-8').scrub
      end
    end
  end
end
