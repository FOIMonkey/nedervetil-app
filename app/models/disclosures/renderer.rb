require 'tmpdir'

module Disclosures
  # Renders a disclosure attachment into pages inside a sandboxed temp dir.
  # PDFs use poppler only, never ImageMagick (whose policy forbids PDF).
  class Renderer
    THUMBNAIL = '240x340'.freeze
    MIN_TEXT = 40
    # OCR-trigger thresholds for text pages (PDFRedactor::Survey): pictures
    # >= 1% of page area can hold text; smaller ones are rules/icons.
    PICTURE_SHARE = 0.01
    # Twenty glyphs that map to no text are more than a stray symbol or two.
    UNMAPPED_GLYPHS = 20
    # Under a tenth of a page's glyphs, the words around them still read.
    UNMAPPED_SHARE = 0.1
    MAX_PAGE_TEXT = 200_000
    MAX_PNG = 64.megabytes
    TEXT_PART = 100_000
    PART_OVERLAP = 1_000
    # Mirrors ImageMagick policy limits on CLI so all environments match.
    MAGICK_LIMITS = (AttachmentManagement::Engines::Raster::MAGICK_LIMITS +
                     %w[-limit width 5000 -limit height 5000
                        -limit area 25MP]).freeze
    # Matches core's "xxx@xxxxx.xxx" redactions (including space-split runs) so
    # text masks don't re-flag already-masked addresses.
    XED_RUN = 'x+(?: x+)*'.freeze
    XED_LOCAL = "#{XED_RUN}(?: ?\\. ?#{XED_RUN})*".freeze
    XED_DOMAIN = "#{XED_RUN}(?: ?\\. ?#{XED_RUN})+".freeze
    XED_EMAIL = /(?<![\w.@])#{XED_LOCAL} ?@ ?#{XED_DOMAIN}(?![\w@])/
    BLOCKS = %w[address article aside blockquote caption dd div dl dt fieldset
                figcaption figure footer form h1 h2 h3 h4 h5 h6 header hr li
                main nav ol p pre section table tr ul].freeze
    # Whitespace-stripped CSS patterns that can hide text beyond inline
    # display:none / visibility:hidden (which html_text strips).
    HIDING_CSS = [
      /display:none/, /visibility:(?:hidden|collapse)/,
      /content-visibility:hidden/, /mso-hide/,
      /font-size:(?:0*\.?0*|[01](?:\.\d*)?(?:px|pt))(?:[;}!]|\z)/,
      /opacity:0*\.?0*(?:[;}!]|\z)/,
      /(?:^|[;{])(?:max-)?(?:height|width):0*\.?0*(?:px|pt|em|%)?(?:[;}!]|\z)/,
      # rubocop:disable Layout/LineLength
      /(?:^|[;{])(?:left|top|right|bottom|text-indent|margin-left|margin-top):-\d{3,}/,
      /(?:^|[;{])color:(?:transparent|white|#fff\b|#ffffff\b|rgba\([^)]*,0*\.?0*\))/,
      # rubocop:enable Layout/LineLength
      /(?:^|[;{])(?:clip|clip-path|transform):/, /z-index:-/
    ].freeze

    # Extracts browser-visible text, stripping Word metadata in head/comments.
    def self.html_text(html)
      page = Nokogiri::HTML(html)
      page.xpath('//comment() | //head | //script | //style | //template | ' \
                 '//noscript | //*[@hidden]').remove
      page.xpath('//*[@style]').each do |node|
        if node['style'].to_s.downcase.delete(" \t\r\n").
             match?(/display:none|visibility:hidden/)
          node.remove
        end
      end
      page.xpath('//text()').each do |node|
        unless node.ancestors('pre').any?
          node.content = node.content.gsub(/[[:space:]]+/, ' ')
        end
      end
      page.css(BLOCKS.join(',')).each do |node|
        node.add_previous_sibling(Nokogiri::XML::Text.new("\n", page))
        node.add_next_sibling(Nokogiri::XML::Text.new("\n", page))
      end
      page.css('td, th').each do |node|
        node.add_next_sibling(Nokogiri::XML::Text.new("\t", page))
      end
      page.css('br').each do |node|
        node.replace(Nokogiri::XML::Text.new("\n", page))
      end
      page.text.split("\n").map { |line| line.gsub(/ {2,}/, ' ').strip }.
        join("\n").gsub(/\n{3,}/, "\n\n").strip
    end

    # True if HTML uses CSS hiding rules that html_text does not evaluate.
    def self.hiding_styles?(html)
      page = Nokogiri::HTML(html)
      if page.xpath('//link[contains(translate(@rel, "STYLESHEET", ' \
                    '"stylesheet"), "stylesheet")]').any?
        return true
      end

      css = page.xpath('//style').map(&:text)
      css += page.xpath('//*[@style]').map { |node| node['style'].to_s }.
        reject do |style|
          style.downcase.delete(" \t\r\n").
            match?(/display:none|visibility:hidden/)
        end
      css += page.xpath('//font[@color]').
        map { |node| "color:#{node['color']}" }
      css.any? do |rules|
        rules = rules.downcase.delete(" \t\r\n")
        rules.include?('@import') ||
          HIDING_CSS.any? { |pattern| rules.match?(pattern) }
      end
    end

    KINDS = { 'pdf' => PDF,
              'spreadsheet' => Workbook,
              'csv' => Csv,
              'document' => Office,
              'presentation' => Office,
              'text' => Text,
              'image' => Image }.freeze

    attr_reader :document, :attachment

    def initialize(document)
      @document = document
      @attachment = document.foi_attachment
      @outcome = Outcome.new
    end

    def run
      unless attachment&.file&.attached?
        raise Error::Refused, _('There is no stored file to render.')
      end

      document.purge_public_pages!
      bytes = attachment.file.download
      format = Formats.for(attachment.content_type, attachment.filename, bytes)
      kind = KINDS.fetch(format, Unknown).new(document, format, @outcome)
      extension = Formats.safe_extension(attachment.filename,
                                         attachment.content_type)
      sections = [guard_section(format), *kind.office_sections].compact.uniq
      AttachmentManagement.sandboxed(
        input: bytes, input_name: "file#{extension}"
      ) do |job|
        OfficePackage::Isolated.read(sections, job: job,
                                               sheets: Sheets.limits) do |read|
          guard(read, format)
          kind.render(job, read)
        end
      end
      document.update!(format: format,
                       page_count: outcome.page_count,
                       render_notes: outcome.render_notes,
                       hidden_content: outcome.findings.uniq)
    end

    private

    attr_reader :outcome

    def guard_section(format)
      return unless Formats::MAIN_PART.key?(format)
      return if Formats.legacy_office?(attachment.content_type,
                                       attachment.filename)

      format == 'spreadsheet' ? 'guard' : 'guard_unpack'
    end

    def guard(read, format)
      section = guard_section(format) or return

      ZipGuard.checked!(read, unpack: section == 'guard_unpack')
    rescue Zip::Error
      raise Error::Refused, _(Formats::REFUSED)
    end
  end
end
