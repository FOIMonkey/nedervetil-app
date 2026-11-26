module AuthorityFeeds
  Result = Struct.new(:rows, :problems, :existing_count, :unmatched, :notes,
                      keyword_init: true) do
    def new_count
      rows.size - existing_count
    end
  end
end
