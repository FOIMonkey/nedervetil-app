module AuthorityFeeds
  # The notes on the authority and on its tags, placed by style. "{county}" in
  # a note becomes a link to the authority its county: tag names; a note that
  # needs one shows only where there is one.
  class Notes
    PLACES = { 'red' => :warning,
               'blue' => :card,
               'green' => :card,
               'yellow' => :caveat,
               'original' => :caveat }.freeze
    COUNTY = '{county}'.freeze

    def initialize(body)
      @body = body
    end

    def for(place)
      all.select do |note|
        PLACES.fetch(note.style, :caveat) == place &&
          (county || !needs_county?(note))
      end
    end

    def county
      return @county if defined?(@county)

      value = @body.tags.find do |tag|
        tag.name == 'county' && tag.value.present?
      end&.value
      @county = value && PublicBody.find_by_url_name(value)
    end

    private

    def all
      @all ||= @body.notes
    end

    def needs_county?(note)
      note.to_plain_text.include?(COUNTY)
    end
  end
end
