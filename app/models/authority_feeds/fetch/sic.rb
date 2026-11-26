module AuthorityFeeds
  module Fetch
    # Scrapes recent decisions from the Scottish Information Commissioner's
    # decisions table (foi.scot), stopping at the first fully known page.
    class Sic
      URL = 'https://www.foi.scot/decisions'.freeze
      MAX_PAGES = 20

      def initialize(http: Http.new, known: ->(_references) { [] })
        @http = http
        @known = known
      end

      def notices
        (0...MAX_PAGES).each_with_object([]) do |page, found|
          rows = rows(
            Nokogiri::HTML(@http.get(page.zero? ? URL : "#{URL}?page=#{page}"))
          )
          references = rows.map { |row| row[:reference] }
          fresh = references - found.map { |row| row[:reference] } -
                  @known.call(references)
          found.concat(rows)
          break found if fresh.empty?
        end
      end

      private

      def rows(html)
        html.css('table tbody tr').filter_map do |tr|
          cells = tr.css('td')
          link = cells[0]&.at_css('a')
          next unless cells.size >= 5 && link

          decided_on =
            begin
              Date.strptime(cells[4].text.strip, '%d/%m/%Y')
            rescue Date::Error
              nil
            end
          next unless decided_on

          { authority_name: cells[1].text.squish,
            decided_on: decided_on,
            reference: link.text.squish,
            title: cells[2].text.squish.
              delete_suffix('[...] view full decision').
              delete_suffix('[...]').squish,
            outcome: cells[3].text.squish,
            url: AuthorityGroups::ExternalRelease.
              normalise_url(URI.join(URL, link['href'].to_s).to_s) }
        end
      end
    end
  end
end
