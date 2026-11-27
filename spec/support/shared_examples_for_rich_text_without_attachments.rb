RSpec.shared_examples 'a rich text field without attachments' do |field|
  let(:blob) do
    ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new('uploaded'), filename: 'uploaded.txt'
    )
  end

  let(:html) do
    '<div><strong>Bold</strong> and <a href="https://example.com/">a link</a>' \
      "<action-text-attachment sgid=\"#{blob.attachable_sgid}\">" \
      '</action-text-attachment></div>'
  end

  def stored(record, field)
    record.class.find(record.id).public_send(field)
  end

  def expect_no_attachments(rich_text)
    expect(rich_text.body.to_html).not_to include('action-text-attachment')
    expect(rich_text.embeds).to be_empty
  end

  it 'removes attachments when saved' do
    record.public_send("#{field}=", html)
    record.save!

    expect_no_attachments(stored(record, field))
  end

  it 'purges an unattached blob referenced by a stripped attachment' do
    record.public_send("#{field}=", html)

    perform_enqueued_jobs { record.save! }

    expect(ActiveStorage::Blob.exists?(blob.id)).to be(false)
  end

  it 'keeps a blob referenced by a stripped attachment when used elsewhere' do
    other = ActionText::RichText.create!(
      record: FactoryBot.create(:public_body), name: 'other', body: 'x'
    )
    ActiveStorage::Attachment.create!(
      name: 'embeds', record: other, blob: blob
    )
    record.public_send("#{field}=", html)

    perform_enqueued_jobs { record.save! }

    expect(ActiveStorage::Blob.exists?(blob.id)).to be(true)
  end

  it 'removes attachments sent in Trix markup' do
    trix = "<p>Text</p><figure data-trix-attachment='" \
      "#{{ sgid: blob.attachable_sgid }.to_json}'></figure>"
    record.public_send("#{field}=", trix)
    record.save!

    expect_no_attachments(stored(record, field))
  end

  it 'removes attachments when saved without validation' do
    record.public_send("#{field}=", html)
    record.save!(validate: false)

    expect_no_attachments(stored(record, field))
  end

  it 'removes attachments when the rich text is saved without validation' do
    record.save!
    rich_text = record.public_send(field)
    rich_text.body = html
    rich_text.save!(validate: false)

    expect_no_attachments(stored(record, field))
  end

  it 'removes attachments from another locale' do
    record.save!
    translation = record.translations.find_or_initialize_by(locale: 'es')
    translation.public_send("#{field}=", html)
    translation.save!

    expect_no_attachments(translation.reload.public_send(field))
  end

  it 'keeps formatting and links' do
    record.public_send("#{field}=", html)
    record.save!

    body = stored(record, field).body
    expect(body.to_html).to include('<strong>Bold</strong>')
    expect(body.links).to eq(['https://example.com/'])
  end

  context 'when an attachment was stored before' do
    before do
      record.public_send("#{field}=", '<p>Before</p>')
      record.save!
      rich_text = record.public_send(field)
      ActiveStorage::Attachment.create!(
        name: 'embeds', record: rich_text, blob: blob
      )
      rich_text.update_column(:body, html)
      record.reload
    end

    it 'is stored to begin with' do
      expect(stored(record, field).embeds.blobs).to eq([blob])
    end

    it 'removes it on the next save' do
      record.public_send("#{field}=", "#{html}<p>Edited</p>")
      record.save!

      expect_no_attachments(stored(record, field))
    end

    it 'purges the blob' do
      record.public_send("#{field}=", "#{html}<p>Edited</p>")

      perform_enqueued_jobs { record.save! }

      expect(ActiveStorage::Blob.exists?(blob.id)).to be(false)
    end

    it 'keeps the blob when something else still uses it' do
      other = ActionText::RichText.create!(
        record: FactoryBot.create(:public_body), name: 'other', body: 'x'
      )
      ActiveStorage::Attachment.create!(
        name: 'embeds', record: other, blob: blob
      )
      record.public_send("#{field}=", "#{html}<p>Edited</p>")

      perform_enqueued_jobs { record.save! }

      expect(ActiveStorage::Blob.exists?(blob.id)).to be(true)
    end
  end
end
