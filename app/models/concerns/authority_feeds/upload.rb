module AuthorityFeeds
  # Shared upload-preview-apply lifecycle for admin CSV imports. Including
  # models configure text_column, no_file_message, encoding_message, and define
  # reader and save_rows(result) -> { added:, updated: }.
  module Upload
    extend ActiveSupport::Concern

    # The preview reads the whole file again on every view.
    MAX_BYTES = 10.megabytes

    class Refused < StandardError; end

    included do
      cattr_accessor :text_column, :no_file_message, :encoding_message,
                     instance_accessor: false
    end

    class_methods do
      def start!(file:, user:, **attributes)
        raise Refused, no_file_message unless file.respond_to?(:read)
        if file.size > MAX_BYTES
          raise Refused, 'The file is over 10 MB. Split it.'
        end

        bytes = file.read.to_s.b
        # PostgreSQL text rejects NUL bytes (also catches UTF-16 files).
        raise Refused, encoding_message if bytes.include?("\0")

        where(state: 'preview').where(created_at: ...1.day.ago).delete_all
        name = File.basename(file.original_filename.to_s).first(255)
        create!(user: user, filename: name, **attributes) do |upload|
          upload[text_column] = text(bytes)
        end
      end

      # Decodes UTF-8 (stripping BOM) with Windows-1252 fallback.
      def text(bytes)
        text = bytes.to_s.dup.force_encoding(Encoding::UTF_8)
        unless text.valid_encoding?
          text = bytes.to_s.encode(Encoding::UTF_8, Encoding::Windows_1252,
                                   invalid: :replace, undef: :replace)
        end
        text.delete_prefix("\uFEFF")
      end
    end

    def preview?
      state == 'preview'
    end

    def applied?
      state == 'applied'
    end

    def result
      @result ||= reader.result
    end

    def apply!
      with_lock do
        raise Refused, 'This import has already been applied.' unless preview?

        fresh = reader.result
        counts = save_rows(fresh)
        self[self.class.text_column] = nil
        update!(state: 'applied', applied_at: Time.current,
                rows_count: fresh.rows.size, added_count: counts[:added],
                updated_count: counts[:updated],
                skipped_count: fresh.problems.size)
      end
    end
  end
end
