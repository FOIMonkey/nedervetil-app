module Disclosures
  # Checks page text for the requester's name/email and partial-check warnings.
  # Partial checks count as hits because unchecked parts may name the requester.
  # See doc/FORK.md.
  module Checks
    Hit = Struct.new(:page, :label, :anchor, :what, keyword_init: true)
    PageText = Struct.new(:number, :label, :anchor, :text, keyword_init: true)
    TITLES = %w[Mr Mrs Ms Miss Mx Dr].freeze
    QUOTES = '’‘ʼ`´'.freeze
    # English/Welsh greeting prefixes; first names only match after one and
    # capitalised to avoid officers and common words ("may", "will").
    GREETINGS = [
      %w[Dear], %w[Hello], %w[Hi], %w[Hey], %w[Thank you],
      %w[Good morning], %w[Good afternoon], %w[Good evening],
      %w[Ann?wyll?], %w[Helo], %w[Shwmae], %w[Shw mae],
      ["S[#{QUOTES}']mae"],
      %w[Bore da], %w[Prynhawn da], %w[Noswaith dda],
      %w[Diolch yn fawr iawn], %w[Diolch yn fawr], %w[Diolch]
    ].freeze
    # Require trailing punctuation so "our thanks will go" doesn't match.
    THANKS = [%w[Many thanks], %w[Thanks]].freeze
    PHRASE_END = '[,.!:;–—-]'.freeze
    # Minimum length for matching a name or surname standalone.
    ALONE = 4

    # Regexp sources (or nil): context before (not captured), name, and after.
    Form = Struct.new(:kind, :label, :before, :name, :after,
                      keyword_init: true)

    module_function

    def flagged_unread(reasons)
      if reasons == ['pictures']
        _('its pictures couldn’t be read, so what they show isn’t checked ' \
          'here')
      elsif reasons == ['glyphs']
        _('some of its text doesn’t map to letters and couldn’t be read, so ' \
          'it isn’t checked here')
      else
        _('it couldn’t be read as it shows, so it isn’t fully checked here')
      end
    end

    def personal(document)
      user = document.requester
      return [] unless user

      names = names_of(user)
      needles = rules(names, user.email).
        map { |pattern, what, _kind| [pattern, what] }
      words = possible_words(names, user.email) or return []
      pages = document.pages.to_a
      pages = attachment_pages(document) if pages.empty?
      pages.flat_map do |page|
        next [] unless page.text.to_s.match?(words)

        text = even(page.text)
        needles.filter_map do |pattern, what|
          next unless text.match?(pattern)

          Hit.new(page: page.number,
                  label: page.label,
                  anchor: page.anchor,
                  what: what)
        end
      end
    end

    def attachment_pages(document)
      attachment = document.try(:foi_attachment)
      return [] unless readable_original?(attachment)

      bytes = attachment.body
      return [] if bytes.blank?

      format = Formats.for(attachment.content_type, attachment.filename, bytes)
      if format == 'text' &&
         !Formats.html?(attachment.content_type, attachment.filename)
        text = convert_string_to_utf8(bytes.dup, 'UTF-8').string
        [PageText.new(number: 1, label: 'Text', anchor: 'page-1', text: text)]
      elsif format == 'pdf'
        extract_pdf_pages(bytes)
      else
        []
      end
    end

    def readable_original?(attachment)
      return false unless attachment&.file&.attached? && !attachment.erased? &&
                          !attachment.masking_failed?
      return false if attachment.rasterized?

      true
    end

    def extract_pdf_pages(bytes)
      AttachmentManagement.sandboxed(input: bytes,
                                     input_name: 'file.pdf') do |job|
        PDFText.pages(job.input, Disclosures.render_max_pages, job.scratch,
                      job: job).map do |page|
          PageText.new(number: page.number,
                       label: "Page #{page.number}",
                       anchor: "page-#{page.number}",
                       text: page.text)
        end
      end
    rescue AttachmentManagement::Command::Failed,
           AttachmentManagement::Unsupported,
           AlaveteliSandbox::Refused
      []
    end

    def partial(version)
      notes = version.render_notes || {}
      cut_sheets(version) +
        pages_past_render_limit(version, notes) +
        pages_past_ocr_limit(version, notes) +
        flagged_pages_unread(version, notes) +
        scans_unread(version, notes) +
        hiding_styles(notes) +
        no_preview(notes)
    end

    def cut_sheets(version)
      version.pages.
        select { |page| page.kind == 'sheet' && page.truncated }.
        map do |page|
          label = if version.format == 'csv'
                    _('The file')
                  else
                    "Sheet “#{page.label}”"
                  end
          Hit.new(page: page.number,
                  label: label,
                  anchor: page.anchor,
                  what: sheet_coverage(page))
        end
    end

    def pages_past_render_limit(version, notes)
      last = version.pages.last
      return [] unless notes['pages_not_shown'].to_i.positive? && last

      [Hit.new(page: last.number,
               label: last.label,
               anchor: last.anchor,
               what: _('{{count}} more pages after it aren’t shown ' \
                       'or checked here',
                       count: notes['pages_not_shown']))]
    end

    def pages_past_ocr_limit(version, notes)
      Array(notes['ocr_skipped']).filter_map do |number|
        page = version.pages.
          find { |candidate| candidate.number == number } or next
        Hit.new(page: number,
                label: page.label,
                anchor: page.anchor,
                what: _('not read (past the limit of pages read by ' \
                        'OCR), so not checked here'))
      end
    end

    def flagged_pages_unread(version, notes)
      Array(notes['unread_flagged']).filter_map do |flagged|
        page = version.pages.
          find { |candidate| candidate.number == flagged['page'] } or next
        Hit.new(page: page.number,
                label: page.label,
                anchor: page.anchor,
                what: flagged_unread(flagged['reasons']))
      end
    end

    def scans_unread(version, notes)
      unread = Array(notes['unread_pages']).sort
      first = version.pages.find { |page| page.number == unread.first }
      return [] unless first

      label = if unread.size == 1
                first.label
              else
                _('Pages {{pages}}', pages: page_list(unread))
              end
      [Hit.new(page: first.number,
               anchor: first.anchor,
               label: label,
               what: _('its text couldn’t be read from the scan, so ' \
                       'it isn’t shown or checked here'))]
    end

    def hiding_styles(notes)
      return [] unless notes['hiding_styles']

      [Hit.new(page: nil,
               label: _('The file'),
               anchor: 'checks-title',
               what: _('has styles that can hide text, which this ' \
                       'site can’t follow, so the text here may ' \
                       'include words the page doesn’t show'))]
    end

    def no_preview(notes)
      return [] unless notes['no_preview'].present?

      [Hit.new(page: nil,
               label: _('The file'),
               anchor: 'checks-title',
               what: _('couldn’t be shown or checked here'))]
    end

    def sheet_coverage(page)
      count = ->(number) {
        ActiveSupport::NumberHelper.number_to_delimited(number)
      }
      rows = page.rows.to_i
      if rows > Disclosures.sheet_max_rows
        shown = [Disclosures.sheet_display_rows, Disclosures.sheet_max_rows].min
        _('rows {{first}}–{{last}} aren’t shown here',
          first: count.call(shown + 1),
          last: count.call(rows))
      else
        _('only part of it is checked here (it has {{rows}} rows and ' \
          '{{columns}} columns)',
          rows: count.call(page.rows),
          columns: count.call(page.columns))
      end
    end

    def unreadable_pages(version)
      version.pages.
        select { |page| page.kind == 'image' && page.text_source == 'none' }
    end

    # Publication check pairs; editor suggestions use rules_for for kind alone.
    def needles_for(user)
      rules_for(user).map { |pattern, what, _kind| [pattern, what] }
    end

    def rules_for(user)
      rules(names_of(user), user.email)
    end

    def rules(names, email)
      needles = []
      email = even(email).strip
      if email.present?
        needles << [word("(?<name>#{phrase(email)})"),
                    PlainTextTranslation._(
                      'the requester’s email address (“{{email}}”)',
                      email: email
                    ),
                    'email']
      end
      needles + name_forms(names).map do |form|
        [word("#{form.before}(?<name>#{form.name})#{form.after}"),
         form.label, form.kind]
      end
    end

    def names?(user, text)
      text = even(text)
      rules_for(user).any? { |pattern, _what, _kind| text.match?(pattern) }
    end

    # Uses raw user[:name] (User#name adds a suspended note) plus EarlierNames,
    # excluding erased-account placeholders.
    def names_of(user)
      removed = ['[Name Removed]', _('[Name Removed]')]
      [user[:name], *EarlierNames.of(user)].
        reject { |name| name.blank? || removed.include?(name) }.
        map { |name| name_parts(name) }.reject(&:empty?).uniq
    end

    def name_parts(name)
      parts = even(name).split
      while parts.size > 1 &&
            TITLES.any? { |title| title.casecmp?(parts.first.delete('.')) }
        parts.shift
      end
      parts
    end

    # Shared with NameMask so every detected form can be masked in a PDF.
    # space matches inter-word gaps; &literal formats each name token.
    def name_forms(names, space: '\\s+', &literal)
      literal ||= ->(text) { phrase(text) }
      names.flat_map { |parts| forms_of(parts, space, literal) }.
        uniq { |form| [form.before, form.name, form.after] }
    end

    def forms_of(parts, space, literal)
      name = parts.join(' ')
      first = parts.first
      surname = parts.last if parts.size > 1
      forms = []
      if name.length >= ALONE
        forms << Form.new(kind: 'name', label: name_label(name),
                          name: literal.call(name))
      end
      forms.concat(surname_forms(first, surname, space, literal)) if surname
      forms.concat(addressed_forms(first, space, literal))
    end

    # Short surnames (< ALONE) require a title, capitalised initial, or
    # "Surname, First/F." (full stop avoids "in May, I asked").
    def surname_forms(first, surname, space, literal)
      forms = [Form.new(
        kind: 'title',
        label: PlainTextTranslation._(
          'the requester’s surname after a title (“{{surname}}”)',
          surname: surname
        ),
        before: "(?:#{TITLES.join('|')})\\.?#{space}",
        name: literal.call(surname)
      )]
      if surname.length >= ALONE
        return forms << Form.new(
          kind: 'surname',
          label: PlainTextTranslation._(
            'the requester’s surname (“{{surname}}”)', surname: surname
          ),
          name: literal.call(surname)
        )
      end

      initial = "(?-i:#{Regexp.escape(first[0].upcase)})"
      surname_source = capital(surname) + literal.call(surname)
      forms << Form.new(
        kind: 'name', label: name_label("#{first[0].upcase} #{surname}"),
        name: "#{initial}(?:\\.(?:#{space}|)|#{space})#{surname_source}"
      )
      forms << Form.new(
        kind: 'name', label: name_label("#{surname}, #{first}"),
        name: "#{surname_source},#{space}" \
              "(?:#{capital(first)}#{literal.call(first)}|#{initial}\\.)"
      )
    end

    # Zero-width lookahead requiring an uppercase initial letter.
    def capital(name)
      letter = name.unicode_normalize(:nfkc)[0].upcase
      letter.size == 1 ? "(?=(?-i:#{Regexp.escape(letter)}))" : ''
    end

    def addressed_forms(first, space, literal)
      label = PlainTextTranslation._(
        'the requester’s first name in a greeting (“{{name}}”)', name: first
      )
      name = capital(first) + literal.call(first)
      [Form.new(kind: 'greeting', label: label,
                before: "#{any_of(GREETINGS, space)},?#{space}", name: name),
       Form.new(kind: 'greeting', label: label,
                before: "#{any_of(THANKS, space)},?#{space}", name: name,
                after: "(?=(?:#{space}|)(?:#{PHRASE_END}|\\z))")]
    end

    def name_label(name)
      PlainTextTranslation._('the requester’s name (“{{name}}”)', name: name)
    end

    def any_of(phrases, space)
      "(?:#{phrases.map { |words| words.join(space) }.join('|')})"
    end

    # Fast pre-filter before even(). ʼ is excluded from word-boundary alnum
    # because even() normalises it to an apostrophe.
    def possible_words(names, email)
      words = (names.flatten + even(email).split).uniq
      return if words.empty?

      alternatives = words.
        map { |part| Regexp.escape(part).gsub("'", "[#{QUOTES}']") }
      # rubocop:disable Layout/LineLength
      /(?<![[:alnum:]&&[^ʼ]])(?:#{alternatives.join('|')})(?![[:alnum:]&&[^ʼ]])/i
      # rubocop:enable Layout/LineLength
    end

    def phrase(text)
      text.split.map { |part| Regexp.escape(part) }.join('\s+')
    end

    def word(source)
      /(?<![[:alnum:]])#{source}(?![[:alnum:]])/i
    end

    def even(text)
      text.to_s.tr(QUOTES, "'").gsub(/[[:space:]]+/, ' ')
    end

    # [1, 2, 3, 5] -> "1–3, 5"
    def page_list(numbers)
      numbers.slice_when { |a, b| b != a + 1 }.map do |run|
        run.size > 1 ? "#{run.first}–#{run.last}" : run.first.to_s
      end.join(', ')
    end
  end
end
