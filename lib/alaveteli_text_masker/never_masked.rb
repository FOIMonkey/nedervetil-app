module AlaveteliTextMasker
  # A picture. Images are never masked, by design, so they go as they came,
  # unmarked.
  class NeverMasked < Pass
    def apply(text)
      text
    end
  end
end
