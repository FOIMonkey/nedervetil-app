# == Schema Information
#
# Table name: external_release_imports
#
#  id            :bigint           not null, primary key
#  user_id       :bigint
#  filename      :string
#  state         :string           default("preview"), not null
#  csv           :text
#  rows_count    :integer          default(0), not null
#  added_count   :integer          default(0), not null
#  updated_count :integer          default(0), not null
#  skipped_count :integer          default(0), not null
#  applied_at    :datetime
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#

module AuthorityGroups
  # Applying adds new links and updates known ones, but never deletes,
  # unhides or unpins, and leaves the title and date of anything an admin has
  # edited.
  class ReleaseImport < ApplicationRecord
    include AuthorityFeeds::Upload

    self.table_name = 'external_release_imports'
    self.text_column = :csv
    self.no_file_message = 'Choose a CSV file.'
    self.encoding_message = 'Save the file as CSV UTF-8 and try again.'

    belongs_to :user, optional: true
    has_many :releases, class_name: 'AuthorityGroups::ExternalRelease',
                        foreign_key: :external_release_import_id,
                        inverse_of: :import,
                        dependent: :nullify

    private

    def reader
      ReleaseCsv.new(csv)
    end

    def save_rows(result)
      upsert(result.rows)
      { added: result.new_count, updated: result.existing_count }
    end

    def upsert(rows)
      now = Time.current
      rows.each_slice(AuthorityFeeds::BATCH) do |slice|
        ExternalRelease.upsert_all(
          slice.map do |row|
            { public_body_id: row.public_body_id,
              title: row.title,
              url: row.url,
              url_key: row.url_key,
              released_on: row.released_on,
              log_url: row.log_url,
              external_release_import_id: id,
              created_at: now,
              updated_at: now }
          end,
          unique_by: %i[public_body_id url_key], record_timestamps: false,
          on_duplicate: Arel.sql(<<~SQL.squish)
            title = CASE WHEN external_releases.edited_at IS NULL THEN EXCLUDED.title ELSE external_releases.title END,
            released_on = CASE WHEN external_releases.edited_at IS NULL THEN EXCLUDED.released_on
                               ELSE external_releases.released_on END,
            log_url = COALESCE(EXCLUDED.log_url, external_releases.log_url),
            updated_at = EXCLUDED.updated_at
          SQL
        )
      end
    end
  end
end
