require 'time'

module Disclosures
  # Publications, newest first. Only listed documents are returned or used in a
  # cursor.
  class PublicationFeed
    PAGE_SIZE = 20
    BATCH_SIZE = 64
    MAX_CANDIDATES = 2_048
    PURPOSE = 'disclosures-publication-feed-v1'.freeze
    class InvalidCursor < StandardError; end
    class ScanLimit < StandardError; end

    attr_reader :next_cursor

    def initialize(cursor: nil)
      @upper, @position = cursor.nil? ? [Time.current.utc, nil] : decode(cursor)
      @scanned = 0
      @exhausted = false
      @selected = []
    end

    def records
      return @records if defined?(@records)

      loop do
        # Need > PAGE_SIZE visible records to prove a next page exists.
        select_candidates until @selected.size > PAGE_SIZE || @exhausted
        # Withdrawals during scanning must also disappear from this response.
        visible = still_listed
        if visible.size > PAGE_SIZE || @exhausted
          @records = visible.first(PAGE_SIZE)
          @next_cursor = encode(@records.last) if visible.size > PAGE_SIZE
          return @records
        end
        @selected = visible.map do |record|
          [record.id, record.first_published_at, record.public_id]
        end
      end
    end

    private

    def select_candidates
      # Fail generically rather than leak an unlisted row in a cursor.
      raise ScanLimit if @scanned >= MAX_CANDIDATES

      limit = batch_limit
      candidates = candidate_batch
      @scanned += candidates.size
      valid = Document.listed.where(id: candidates.map(&:first)).
        pluck('disclosure_documents.id')
      candidates.each_with_index do |candidate, index|
        id, timestamp, public_id = candidate
        @position = [timestamp, public_id]
        @selected << candidate if valid.include?(id)
        if @selected.size > PAGE_SIZE
          @exhausted = index == candidates.size - 1 && candidates.size < limit
        end
        break if @selected.size > PAGE_SIZE
      end
      if candidates.empty? ||
         (candidates.size < limit && @selected.size <= PAGE_SIZE)
        @exhausted = true
      end
    end

    def batch_limit
      [BATCH_SIZE, MAX_CANDIDATES - @scanned].min
    end

    def candidate_batch
      relation = Document.where(state: 'published').
        where.not(first_published_at: nil).
        where('first_published_at <= ?', @upper)
      if @position
        relation = relation.where('(first_published_at, public_id) < (?, ?)',
                                  *@position)
      end
      relation.order(first_published_at: :desc, public_id: :desc).
        limit(batch_limit).
        pluck(:id, :first_published_at, :public_id)
    end

    def still_listed
      current = Document.listed.where(id: @selected.map(&:first)).
        preload(public_body: :translations).
        index_by(&:id)
      @selected.filter_map do |id, timestamp, public_id|
        record = current[id]
        if record && record.first_published_at == timestamp &&
           record.public_id == public_id
          record
        end
      end
    end

    def verifier
      Rails.application.message_verifier(PURPOSE)
    end

    def encode(record)
      # Only public fields, never skipped or private candidate IDs.
      verifier.generate({ 'v' => 1,
                          'upper' => @upper.iso8601(6),
                          'before' => [record.first_published_at.utc.iso8601(6),
                                       record.public_id] },
                        purpose: PURPOSE,
                        expires_in: 1.day)
    end

    def decode(cursor)
      unless cursor.is_a?(String) && cursor.bytesize <= 2_048
        raise InvalidCursor
      end

      data = verifier.verified(cursor, purpose: PURPOSE)
      raise InvalidCursor unless well_formed?(data)

      upper = Time.iso8601(data['upper']).utc
      position = [Time.iso8601(data['before'][0]).utc, data['before'][1]]
      raise InvalidCursor if position.first > upper

      [upper, position]
    rescue ArgumentError, TypeError
      raise InvalidCursor
    end

    def well_formed?(data)
      data.is_a?(Hash) && data.keys.sort == %w[before upper v] &&
        data['v'] == 1 && data['upper'].is_a?(String) &&
        data['before'].is_a?(Array) && data['before'].size == 2 &&
        data['before'][0].is_a?(String) &&
        data['before'][1].is_a?(String) &&
        data['before'][1].match?(Document::PUBLIC_ID)
    end
  end
end
