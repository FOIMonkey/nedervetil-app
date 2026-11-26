module Disclosures
  class Renderer
    # Any other kind of file: nothing to show.
    class Unknown < Kind
      private

      def pages(_path, _dir)
        outcome.notes['no_preview'] = 'unknown'
        outcome.findings <<
          'This kind of file can’t be shown or checked here.'
      end
    end
  end
end
