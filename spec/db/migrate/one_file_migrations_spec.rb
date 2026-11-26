require 'spec_helper'
require Rails.root.join(
  'db/migrate/20261122000200_prepare_one_file_storage'
).to_s
require Rails.root.join(
  'db/migrate/20261122000300_reparent_pages_and_topics_to_documents'
).to_s
require Rails.root.join(
  'db/migrate/20261122000400_drop_disclosure_versions_and_original'
).to_s
require Rails.root.join(
  'db/migrate/20261122000600_drop_foi_attachment_lock_and_replace_columns'
).to_s

RSpec.describe 'One-file production-safe migrations' do
  let(:connection) { ActiveRecord::Base.connection }

  def run_migration(klass, direction)
    ActiveRecord::Migration.suppress_messages do
      klass.new.public_send(direction)
    end
  end

  describe PrepareOneFileStorage do
    it 'backfills read_at, last_activity_at, and preserves public prominence on published documents' do
      owner = FactoryBot.create(:user)
      request = FactoryBot.create(:info_request, user: owner,
                                                 created_at: 20.days.ago)
      sent_at = 3.days.ago.change(usec: 0)
      request.outgoing_messages.first.update!(status: 'sent',
                                              last_sent_at: sent_at)

      parsed_at = 5.days.ago.change(usec: 0)
      raw_parsed = FactoryBot.create(:raw_email)
      message = FactoryBot.create(:incoming_message, info_request: request,
                                                     raw_email: raw_parsed,
                                                     last_parsed: parsed_at,
                                                     created_at: 6.days.ago)
      raw_unparsed = FactoryBot.create(:raw_email)
      FactoryBot.create(:incoming_message, info_request: request,
                                           raw_email: raw_unparsed,
                                           last_parsed: nil,
                                           created_at: 10.days.ago)

      published_att = FactoryBot.create(:foi_attachment,
                                        incoming_message: message)
      private_att = FactoryBot.create(:foi_attachment,
                                      incoming_message: message)
      hidden_att = FactoryBot.create(:foi_attachment,
                                     incoming_message: message,
                                     prominence: 'hidden')

      Disclosures::Document.create!(
        info_request: request,
        public_body: request.public_body,
        incoming_message: message,
        foi_attachment: published_att,
        source_kind: 'attachment',
        kind: 'released_records',
        title: 'Published PDF',
        state: 'published',
        published_at: 4.days.ago,
        first_published_at: 4.days.ago
      )

      run_migration(PrepareOneFileStorage, :down)
      connection.execute(<<~SQL.squish)
        UPDATE foi_attachments SET prominence = 'normal'
        WHERE id IN (#{published_att.id}, #{private_att.id})
      SQL

      run_migration(PrepareOneFileStorage, :up)

      read_at_parsed = connection.select_value(
        "SELECT read_at FROM raw_emails WHERE id = #{raw_parsed.id}"
      )
      read_at_unparsed = connection.select_value(
        "SELECT read_at FROM raw_emails WHERE id = #{raw_unparsed.id}"
      )
      expect(read_at_parsed).to be_within(1.second).of(parsed_at)
      expect(read_at_unparsed).to be_nil

      activity_at = connection.select_value(
        "SELECT last_activity_at FROM info_requests WHERE id = #{request.id}"
      )
      expect(activity_at).to be_within(1.second).of(sent_at)

      prominences = connection.select_rows(<<~SQL.squish).to_h
        SELECT id, prominence FROM foi_attachments
        WHERE id IN (#{published_att.id}, #{private_att.id}, #{hidden_att.id})
      SQL
      expect(prominences[published_att.id]).to eq('public')
      expect(prominences[private_att.id]).to eq('requester_only')
      expect(prominences[hidden_att.id]).to eq('hidden')
    end
  end

  describe ReparentPagesAndTopicsToDocuments do
    it 'copies published version metadata and reparents pages, thumbnails, and topic matches' do
      owner = FactoryBot.create(:user)
      request = FactoryBot.create(:info_request, user: owner)
      message = AttachmentFixtures.deliver(
        request, [['live.pdf', 'application/pdf', '%PDF-1.4']]
      )
      attachment = message.get_attachments_for_display.first
      doc = Disclosures::Document.create!(
        info_request: request,
        public_body: request.public_body,
        incoming_message: message,
        foi_attachment: attachment,
        source_kind: 'attachment',
        kind: 'released_records',
        title: 'Live document',
        state: 'published'
      )

      connection.create_table(:disclosure_versions) do |t|
        t.bigint :document_id, null: false
        t.integer :number, null: false
        t.string :format
        t.integer :page_count
        t.jsonb :render_notes, null: false, default: {}
        t.jsonb :hidden_content, null: false, default: []
      end
      connection.create_table(:disclosure_publication_revisions) do |t|
        t.bigint :document_id, null: false
        t.bigint :version_id, null: false
      end
      connection.add_column :disclosure_documents, :published_version_id,
                            :bigint
      connection.add_column :disclosure_documents, :current_publication_id,
                            :bigint
      connection.add_column :disclosure_pages, :version_id, :bigint

      run_migration(ReparentPagesAndTopicsToDocuments, :down)

      pub_version_id = connection.select_value(<<~SQL.squish)
        INSERT INTO disclosure_versions
          (document_id, number, format, page_count, render_notes, hidden_content)
        VALUES
          (#{doc.id}, 1, 'pdf', 2, '{"ocr":"off"}'::jsonb, '["note"]'::jsonb)
        RETURNING id
      SQL
      draft_version_id = connection.select_value(<<~SQL.squish)
        INSERT INTO disclosure_versions (document_id, number, format, page_count)
        VALUES (#{doc.id}, 2, 'pdf', 1)
        RETURNING id
      SQL
      pub_rev_id = connection.select_value(<<~SQL.squish)
        INSERT INTO disclosure_publication_revisions (document_id, version_id)
        VALUES (#{doc.id}, #{pub_version_id})
        RETURNING id
      SQL
      connection.execute(<<~SQL.squish)
        UPDATE disclosure_documents
        SET published_version_id = #{pub_version_id},
            current_publication_id = #{pub_rev_id}
        WHERE id = #{doc.id}
      SQL
      published_page_id = connection.select_value(<<~SQL.squish)
        INSERT INTO disclosure_pages
          (version_id, number, kind, text, created_at, updated_at)
        VALUES
          (#{pub_version_id}, 1, 'image', 'Published text', NOW(), NOW())
        RETURNING id
      SQL
      draft_page_id = connection.select_value(<<~SQL.squish)
        INSERT INTO disclosure_pages
          (version_id, number, kind, text, created_at, updated_at)
        VALUES
          (#{draft_version_id}, 1, 'image', 'Draft text', NOW(), NOW())
        RETURNING id
      SQL
      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new('fake-png'),
        filename: 'thumbnail.png',
        content_type: 'image/png',
        service_name: :attachments
      )
      published_file_blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new('published-orange-masked-pdf'),
        filename: 'live.pdf',
        content_type: 'application/pdf',
        service_name: :attachments
      )
      connection.execute(<<~SQL.squish)
        INSERT INTO active_storage_attachments
          (name, record_type, record_id, blob_id, created_at)
        VALUES
          ('thumbnail', 'Disclosures::Version', #{pub_version_id}, #{blob.id}, NOW()),
          ('file', 'Disclosures::Version', #{pub_version_id}, #{published_file_blob.id}, NOW())
      SQL
      connection.execute(<<~SQL.squish)
        INSERT INTO disclosure_topic_matches (topic, publication_revision_id)
        VALUES ('housing', #{pub_rev_id})
      SQL

      run_migration(ReparentPagesAndTopicsToDocuments, :up)

      row = connection.select_one(<<~SQL.squish)
        SELECT format, page_count, render_notes, hidden_content
        FROM disclosure_documents WHERE id = #{doc.id}
      SQL
      expect(row['format']).to eq('pdf')
      expect(row['page_count']).to eq(2)
      expect(JSON.parse(row['render_notes'])).to eq('ocr' => 'off')
      expect(JSON.parse(row['hidden_content'])).to eq(['note'])

      pub_page_doc = connection.select_value(
        "SELECT document_id FROM disclosure_pages " \
        "WHERE id = #{published_page_id}"
      )
      draft_page_doc = connection.select_value(
        "SELECT document_id FROM disclosure_pages WHERE id = #{draft_page_id}"
      )
      expect(pub_page_doc).to eq(doc.id)
      expect(draft_page_doc).to be_nil

      thumb = connection.select_one(<<~SQL.squish)
        SELECT record_type, record_id
        FROM active_storage_attachments
        WHERE blob_id = #{blob.id} AND name = 'thumbnail'
      SQL
      expect(thumb).to eq('record_type' => 'Disclosures::Document',
                          'record_id' => doc.id)

      attachment.reload
      expect(attachment.file.blob_id).to eq(published_file_blob.id)
      expect(attachment.file.download).to eq('published-orange-masked-pdf')

      topics = connection.select_rows(<<~SQL.squish)
        SELECT topic, document_id FROM disclosure_topic_matches
        WHERE document_id = #{doc.id}
      SQL
      expect(topics).to eq([['housing', doc.id]])
    end

    it 'updates filename, content_type, and display_size for converted published versions' do
      docx_type = 'application/vnd.openxmlformats-officedocument.' \
                  'wordprocessingml.document'
      owner = FactoryBot.create(:user)
      request = FactoryBot.create(:info_request, user: owner)
      message = AttachmentFixtures.deliver(
        request,
        [['swapped.docx', docx_type, 'original-docx'],
         ['reparented.docx', docx_type, 'original-docx-2']]
      )
      swapped = message.foi_attachments.find_by!(filename: 'swapped.docx')
      reparented = message.foi_attachments.find_by!(filename: 'reparented.docx')
      reparented.file.purge

      swapped_doc = Disclosures::Document.create!(
        info_request: request,
        public_body: request.public_body,
        incoming_message: message,
        foi_attachment: swapped,
        source_kind: 'attachment',
        kind: 'released_records',
        title: 'Swapped converted document',
        state: 'published'
      )
      reparented_doc = Disclosures::Document.create!(
        info_request: request,
        public_body: request.public_body,
        incoming_message: message,
        foi_attachment: reparented,
        source_kind: 'attachment',
        kind: 'released_records',
        title: 'Reparented converted document',
        state: 'published'
      )

      connection.create_table(:disclosure_versions) do |t|
        t.bigint :document_id, null: false
        t.integer :number, null: false
        t.string :filename
        t.string :content_type
        t.bigint :byte_size
        t.string :format
        t.integer :page_count
        t.jsonb :render_notes, null: false, default: {}
        t.jsonb :hidden_content, null: false, default: []
      end
      connection.create_table(:disclosure_publication_revisions) do |t|
        t.bigint :document_id, null: false
        t.bigint :version_id, null: false
      end
      connection.add_column :disclosure_documents, :published_version_id,
                            :bigint
      connection.add_column :disclosure_documents, :current_publication_id,
                            :bigint
      connection.add_column :disclosure_pages, :version_id, :bigint

      run_migration(ReparentPagesAndTopicsToDocuments, :down)

      swapped_pdf = '%PDF-1.4 ' + ('a' * 24_576)
      swapped_blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(swapped_pdf),
        filename: 'swapped.pdf',
        content_type: 'application/pdf',
        service_name: :attachments
      )
      reparented_blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new('%PDF-1.4 big'),
        filename: 'reparented.pdf',
        content_type: 'application/pdf',
        service_name: :attachments
      )
      reparented_blob.update_column(:byte_size, 1_572_864)

      swapped_ver_id = connection.select_value(<<~SQL.squish)
        INSERT INTO disclosure_versions
          (document_id, number, filename, content_type, byte_size, format)
        VALUES
          (#{swapped_doc.id}, 1, 'swapped.pdf', 'application/pdf',
           #{swapped_pdf.bytesize}, 'pdf')
        RETURNING id
      SQL
      reparented_ver_id = connection.select_value(<<~SQL.squish)
        INSERT INTO disclosure_versions
          (document_id, number, filename, content_type, byte_size, format)
        VALUES
          (#{reparented_doc.id}, 1, 'reparented.pdf', 'application/pdf',
           1572864, 'pdf')
        RETURNING id
      SQL
      connection.execute(<<~SQL.squish)
        UPDATE disclosure_documents
        SET published_version_id = #{swapped_ver_id}
        WHERE id = #{swapped_doc.id}
      SQL
      connection.execute(<<~SQL.squish)
        UPDATE disclosure_documents
        SET published_version_id = #{reparented_ver_id}
        WHERE id = #{reparented_doc.id}
      SQL
      connection.execute(<<~SQL.squish)
        INSERT INTO active_storage_attachments
          (name, record_type, record_id, blob_id, created_at)
        VALUES
          ('file', 'Disclosures::Version', #{swapped_ver_id},
           #{swapped_blob.id}, NOW()),
          ('file', 'Disclosures::Version', #{reparented_ver_id},
           #{reparented_blob.id}, NOW())
      SQL

      run_migration(ReparentPagesAndTopicsToDocuments, :up)

      swapped.reload
      expect(swapped.file.blob_id).to eq(swapped_blob.id)
      expect(swapped.filename).to eq('swapped.pdf')
      expect(swapped.content_type).to eq('application/pdf')
      expect(swapped.display_size).to eq('24K')

      reparented.reload
      expect(reparented.file.blob_id).to eq(reparented_blob.id)
      expect(reparented.filename).to eq('reparented.pdf')
      expect(reparented.content_type).to eq('application/pdf')
      expect(reparented.display_size).to eq('1.5M')
    end
  end

  describe DropDisclosureVersionsAndOriginal do
    it 'removes legacy active_storage_attachments while preserving live blobs' do
      owner = FactoryBot.create(:user)
      request = FactoryBot.create(:info_request, user: owner)
      message = AttachmentFixtures.deliver(
        request, [['live.pdf', 'application/pdf', '%PDF-1.4 live']]
      )
      attachment = message.get_attachments_for_display.first
      raw_email_blob_id = message.raw_email.file_blob.id
      doc = Disclosures::Document.create!(
        info_request: request,
        public_body: request.public_body,
        incoming_message: message,
        foi_attachment: attachment,
        source_kind: 'attachment',
        kind: 'released_records',
        title: 'Published document',
        state: 'published'
      )

      connection.create_table(:disclosure_versions) do |t|
        t.bigint :document_id, null: false
        t.integer :number, null: false
        t.string :filename
        t.string :content_type
        t.bigint :byte_size
        t.string :format
        t.integer :page_count
        t.jsonb :render_notes, null: false, default: {}
        t.jsonb :hidden_content, null: false, default: []
      end
      connection.create_table(:disclosure_publication_revisions) do |t|
        t.bigint :document_id, null: false
        t.bigint :version_id, null: false
      end
      connection.add_column :disclosure_documents, :published_version_id,
                            :bigint
      connection.add_column :disclosure_documents, :current_publication_id,
                            :bigint
      connection.add_column :disclosure_documents, :original_sha256, :string
      connection.add_column :disclosure_documents, :original_filename, :string
      connection.add_column :disclosure_documents, :original_content_type,
                            :string
      connection.add_column :disclosure_documents, :original_byte_size, :bigint
      connection.add_column :disclosure_documents,
                            :original_unavailable_reason, :string
      connection.add_column :disclosure_documents, :original_erase_after,
                            :datetime
      connection.add_column :disclosure_documents, :original_erased_at,
                            :datetime
      connection.add_column :disclosure_pages, :version_id, :bigint
      connection.add_column :disclosure_events, :version_id, :bigint

      run_migration(ReparentPagesAndTopicsToDocuments, :down)

      pub_ver_id = connection.select_value(<<~SQL.squish)
        INSERT INTO disclosure_versions
          (document_id, number, filename, content_type, byte_size, format,
           page_count)
        VALUES
          (#{doc.id}, 1, 'live.pdf', 'application/pdf', 15, 'pdf', 1)
        RETURNING id
      SQL
      old_ver_id = connection.select_value(<<~SQL.squish)
        INSERT INTO disclosure_versions
          (document_id, number, filename, content_type, byte_size, format,
           page_count)
        VALUES
          (#{doc.id}, 2, 'draft.pdf', 'application/pdf', 16, 'pdf', 1)
        RETURNING id
      SQL
      connection.execute(<<~SQL.squish)
        UPDATE disclosure_documents
        SET published_version_id = #{pub_ver_id}
        WHERE id = #{doc.id}
      SQL

      live_page_id = connection.select_value(<<~SQL.squish)
        INSERT INTO disclosure_pages
          (version_id, number, kind, text, created_at, updated_at)
        VALUES (#{pub_ver_id}, 1, 'image', 'Live page', NOW(), NOW())
        RETURNING id
      SQL
      orphan_page_id = connection.select_value(<<~SQL.squish)
        INSERT INTO disclosure_pages
          (version_id, number, kind, text, created_at, updated_at)
        VALUES (#{old_ver_id}, 1, 'image', 'Draft page', NOW(), NOW())
        RETURNING id
      SQL

      upload_blob = ->(name, type, bytes) do
        ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(bytes),
          filename: name,
          content_type: type,
          service_name: :attachments
        )
      end
      pub_file_blob = upload_blob.call('live.pdf', 'application/pdf',
                                       '%PDF-1.4 pub')
      pub_thumb_blob = upload_blob.call('thumb.png', 'image/png', 'live-thumb')
      live_page_blob = upload_blob.call('page1.png', 'image/png', 'live-page')
      old_ver_file_blob = upload_blob.call('draft.pdf', 'application/pdf',
                                           '%PDF-1.4 old')
      old_ver_thumb_blob = upload_blob.call('old-thumb.png', 'image/png',
                                            'old-thumb')
      orphan_page_blob = upload_blob.call('orphan.png', 'image/png',
                                          'orphan-page')
      original_blob = upload_blob.call('orig.pdf', 'application/pdf',
                                       '%PDF-1.4 orig')

      connection.execute(<<~SQL.squish)
        INSERT INTO active_storage_attachments
          (name, record_type, record_id, blob_id, created_at)
        VALUES
          ('file', 'Disclosures::Version', #{pub_ver_id},
           #{pub_file_blob.id}, NOW()),
          ('thumbnail', 'Disclosures::Version', #{pub_ver_id},
           #{pub_thumb_blob.id}, NOW()),
          ('image', 'Disclosures::Page', #{live_page_id},
           #{live_page_blob.id}, NOW()),
          ('file', 'Disclosures::Version', #{old_ver_id},
           #{old_ver_file_blob.id}, NOW()),
          ('thumbnail', 'Disclosures::Version', #{old_ver_id},
           #{old_ver_thumb_blob.id}, NOW()),
          ('image', 'Disclosures::Page', #{orphan_page_id},
           #{orphan_page_blob.id}, NOW()),
          ('original', 'Disclosures::Document', #{doc.id},
           #{original_blob.id}, NOW())
      SQL

      run_migration(ReparentPagesAndTopicsToDocuments, :up)
      run_migration(DropDisclosureVersionsAndOriginal, :up)

      expect(ActiveStorage::Attachment.where(
               record_type: 'Disclosures::Version'
             )).to be_empty
      expect(ActiveStorage::Attachment.where(
               record_type: 'Disclosures::Document', name: 'original'
             )).to be_empty
      expect(ActiveStorage::Attachment.where(
               record_type: 'Disclosures::Page', record_id: orphan_page_id
             )).to be_empty

      unattached_ids = ActiveStorage::Blob.unattached.pluck(:id)
      expect(unattached_ids).to include(
        old_ver_file_blob.id,
        old_ver_thumb_blob.id,
        orphan_page_blob.id,
        original_blob.id
      )
      expect(unattached_ids).not_to include(
        pub_file_blob.id,
        pub_thumb_blob.id,
        live_page_blob.id,
        raw_email_blob_id
      )

      expect(attachment.reload.file.blob_id).to eq(pub_file_blob.id)
      expect(doc.reload.thumbnail.blob_id).to eq(pub_thumb_blob.id)
      expect(Disclosures::Page.find(live_page_id).image.blob_id).
        to eq(live_page_blob.id)
    end
  end

  describe DropFoiAttachmentLockAndReplaceColumns do
    it 'marks legacy replaced_at rows as black_masked and manual_black_mask' do
      owner = FactoryBot.create(:user)
      request = FactoryBot.create(:info_request, user: owner)
      message = AttachmentFixtures.deliver(
        request,
        [['replaced_with_meta.txt', 'text/plain', 'Replaced A'],
         ['replaced_null_meta.txt', 'text/plain', 'Replaced B'],
         ['untouched.txt', 'text/plain', 'Untouched']]
      )
      with_meta = message.foi_attachments.
                  find_by!(filename: 'replaced_with_meta.txt')
      null_meta = message.foi_attachments.
                  find_by!(filename: 'replaced_null_meta.txt')
      untouched = message.foi_attachments.
                  find_by!(filename: 'untouched.txt')

      with_meta.file_blob.update!(metadata: { 'identified' => true })
      connection.execute(<<~SQL.squish)
        UPDATE active_storage_blobs
        SET metadata = NULL
        WHERE id = #{null_meta.file_blob.id}
      SQL

      run_migration(DropFoiAttachmentLockAndReplaceColumns, :down)
      connection.execute(<<~SQL.squish)
        UPDATE foi_attachments
        SET replaced_at = NOW(), black_masked = FALSE
        WHERE id IN (#{with_meta.id}, #{null_meta.id})
      SQL
      connection.execute(<<~SQL.squish)
        UPDATE foi_attachments
        SET replaced_at = NULL, black_masked = FALSE
        WHERE id = #{untouched.id}
      SQL

      run_migration(DropFoiAttachmentLockAndReplaceColumns, :up)

      expect(connection.column_exists?(:foi_attachments, :replaced_at)).
        to be(false)
      expect(connection.column_exists?(:foi_attachments, :replaced_reason)).
        to be(false)
      expect(connection.column_exists?(:foi_attachments, :locked)).to be(false)

      [with_meta, null_meta, untouched].each do |att|
        att.reload
        att.file_blob.reload
      end
      expect(with_meta).to be_black_masked
      expect(with_meta.manual_black_mask?).to be(true)
      expect(with_meta.file_blob.metadata['identified']).to be(true)

      expect(null_meta).to be_black_masked
      expect(null_meta.manual_black_mask?).to be(true)

      expect(untouched).not_to be_black_masked
      expect(untouched.manual_black_mask?).to be(false)
    end
  end
end
