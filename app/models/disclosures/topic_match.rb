module Disclosures
  # Indexed topic matches pointing directly at disclosure_documents.
  class TopicMatch < ApplicationRecord
    self.table_name = 'disclosure_topic_matches'

    SQL = <<~SQL.squish.freeze
      INSERT INTO disclosure_topic_matches (topic, document_id)
      SELECT :topic, documents.id FROM disclosure_documents documents
      WHERE %<documents>s
        AND (documents.search_vector @@ websearch_to_tsquery('english', :words)
             OR EXISTS (SELECT 1 FROM disclosure_pages pages
                        WHERE pages.document_id = documents.id
                          AND pages.search_vector @@ websearch_to_tsquery('english', :words)))
      ON CONFLICT DO NOTHING
    SQL

    def self.record(document)
      where(document_id: document.id).delete_all
      insert_matches(format(SQL, documents: 'documents.id = :id'),
                     id: document.id)
    end

    def self.rebuild
      transaction do
        delete_all
        insert_matches(format(SQL, documents: "documents.state = 'published'"))
      end
    end

    def self.insert_matches(sql, binds = {})
      return unless defined?(Topics::Topic)

      Topics::Topic.all.select(&:search).each do |topic|
        connection.execute(
          sanitize_sql_array(
            [sql, binds.merge(topic: topic.slug, words: topic.search)]
          )
        )
      end
    end
    private_class_method :insert_matches
  end
end
