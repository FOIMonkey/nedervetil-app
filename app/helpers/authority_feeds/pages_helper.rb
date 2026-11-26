module AuthorityFeeds
  # Helpers for the sections of an authority's page.
  module PagesHelper
    def authority_tab_path(body, key)
      case key
      when 'documents'
        public_body_documents_path(url_name: body.url_name)
      when 'foi_record'
        public_body_foi_record_path(url_name: body.url_name)
      else
        public_body_path(body)
      end
    end

    def authority_tile_value(tile)
      if tile.format == :percent
        "#{tile.value}%"
      else
        number_with_delimiter(tile.value)
      end
    end

    def authority_year(year)
      year.to_s.tr('-', '–')
    end

    def authority_date(date)
      if date.year == Date.current.year
        date.strftime('%-d %b')
      else
        date.strftime('%-d %b %Y')
      end
    end

    def authority_note(note, county)
      # A note's own heading sits under the page's sections.
      html = String(note_as_html(note)).gsub(%r{<(/?)h1\b}i, '<\\1h2')
      # rubocop:disable Rails/OutputSafety -- note_as_html sanitised it; the gsub only renames heading tags and split only cuts at the {county} marker
      return html.html_safe unless county && html.include?(Notes::COUNTY)

      parts = html.split(Notes::COUNTY, -1).map(&:html_safe)
      # rubocop:enable Rails/OutputSafety
      safe_join(parts.zip([link_to(county.name, public_body_path(county))] *
                          (parts.size - 1)).flatten.compact)
    end
  end
end
