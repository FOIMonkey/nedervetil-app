module AlaveteliTextMasker
  # Base strategy for AlaveteliTextMasker#apply_masks; subclasses implement
  # #apply.
  class Pass
    def initialize(masker, content_type, options)
      @masker = masker
      @content_type = content_type
      @options = options
    end

    private

    attr_reader :masker, :content_type, :options

    def default_masks
      options[:default_masks] == false ? [] : masker.masks.values
    end
  end
end
