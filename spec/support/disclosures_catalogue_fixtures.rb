# Synthetic catalogue rows for query tests and benchmarks, in the test
# database only.
module DisclosuresCatalogueFixtures
  def expand_catalogue(template, count)
    raise 'Test database only' unless Rails.env.test?

    connection = ActiveRecord::Base.connection
    base = 1_500_000_000
    if Disclosures::Document.exists?(['id > ?', base])
      raise 'Synthetic range already used'
    end

    copy = ->(table, source_id, overrides) do
      generated = connection.select_values(
        'SELECT attname FROM pg_attribute WHERE attrelid = ' \
        "#{connection.quote(table)}::regclass AND attgenerated <> ''"
      )
      columns = connection.columns(table).map(&:name) - generated
      expressions = columns.map do |column|
        overrides.fetch(column,
                        "template.#{connection.quote_column_name(column)}")
      end
      connection.execute(<<~SQL)
        INSERT INTO #{table} (#{columns.map { |column| connection.quote_column_name(column) }.join(', ')})
        SELECT #{expressions.join(', ')} FROM #{table} template CROSS JOIN generate_series(1, #{Integer(count)}) AS n
        WHERE template.id = #{Integer(source_id)}
      SQL
    end
    identity = { 'id' => "#{base} + n" }
    copy.call('info_requests', template.info_request_id,
              identity.merge(
                'url_title' => "'catalogue-benchmark-private-' || n",
                'title' => "'Private source marker ' || n"
              ))
    copy.call('incoming_messages', template.incoming_message_id,
              identity.merge('info_request_id' => "#{base} + n"))
    copy.call('foi_attachments', template.foi_attachment_id,
              identity.merge('incoming_message_id' => "#{base} + n"))
    if (file_attachment = template.foi_attachment.file.attachment)
      copy.call('active_storage_attachments', file_attachment.id,
                identity.merge('record_id' => "#{base} + n"))
    end
    copy.call('disclosure_documents', template.id,
              identity.merge(
                'public_id' => "lpad(n::text, 12, '0')",
                'info_request_id' => "#{base} + n",
                'incoming_message_id' => "#{base} + n",
                'foi_attachment_id' => "#{base} + n",
                'title' => "'Published catalogue ledger ' || n",
                'description' => "'Approved repairs by ward ' || n",
                'document_date' => "DATE '2020-01-01' + (n % 2000)::integer"
              ))
    if (page = template.pages.first)
      copy.call('disclosure_pages', page.id,
                identity.merge('document_id' => "#{base} + n"))
    end
    base
  end
end
