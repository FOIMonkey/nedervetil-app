require 'spec_helper'
require 'tempfile'

RSpec.describe 'Document and attachment file responses' do
  let(:bytes) { "Synthetic file bytes\n".b }
  let(:filename) { 'records.txt' }
  let(:download_policy) { "default-src 'none'; sandbox" }
  let(:preview_policy) do
    "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; sandbox"
  end

  def send_from(controller_class, method, *args, **options)
    controller = controller_class.new
    controller.set_request!(ActionDispatch::TestRequest.create)
    controller.set_response!(ActionDispatch::TestResponse.new)
    controller.send(method, *args, **options)
    controller.response
  end

  def document_response(content_type, **options)
    send_from(Disclosures::BaseController, :send_document_file, bytes,
              filename: filename, content_type: content_type, **options)
  end

  def attachment_response(content_type, **options)
    send_from(AttachmentManagement::BaseController, :send_file_bytes, bytes,
              filename: filename, content_type: content_type, **options)
  end

  %w[text/plain application/pdf image/png text/html
     image/svg+xml].each do |type|
    it "keeps #{type} download headers identical except for CSP" do
      document = document_response(type)
      attachment = attachment_response(type)

      expect(document.body.b).to eq(bytes)
      expect(attachment.body.b).to eq(bytes)
      expect(document.headers.except('Content-Security-Policy')).
        to eq(attachment.headers.except('Content-Security-Policy'))
      expect(document.headers['Content-Disposition']).
        to start_with('attachment;')
      expected_type = type == 'text/plain' ? 'text/plain; charset=utf-8' : type
      expect(document.headers['Content-Type']).to eq(expected_type)
      expect(document.headers['Content-Security-Policy']).to eq(download_policy)
      expect(attachment.headers['Content-Security-Policy']).
        to eq(type == 'application/pdf' ? nil : preview_policy)
    end
  end

  %w[application/pdf image/png image/jpeg image/gif image/webp image/bmp
     text/plain].each do |type|
    it "allows a requested #{type} attachment preview" do
      response = attachment_response(type, inline: true)
      expect(response.body.b).to eq(bytes)
      expect(response.headers['Content-Disposition']).to start_with('inline;')
      expect(response.headers['Content-Security-Policy']).
        to eq(type == 'application/pdf' ? nil : preview_policy)
    end
  end

  %w[text/html image/svg+xml application/octet-stream].each do |type|
    it "downloads #{type} even when an attachment preview is requested" do
      response = attachment_response(type, inline: true)
      expect(response.headers['Content-Disposition']).
        to start_with('attachment;')
      expect(response.headers['Content-Security-Policy']).to eq(preview_policy)
    end
  end

  [nil, '', ' '].each do |type|
    it "downloads a document with #{type.inspect} type as octet-stream" do
      response = document_response(type)
      expect(response.headers['Content-Type']).to eq('application/octet-stream')
      expect(response.headers['Content-Security-Policy']).to eq(download_policy)
    end
  end

  it 'sends the same document bytes and headers from a local path or memory' do
    Tempfile.create('records') do |file|
      file.binmode
      file.write(bytes)
      file.flush
      memory = document_response('text/plain')
      local = document_response('text/plain', path: file.path)
      expect(local.body.b).to eq(memory.body.b)
      expect(local.headers).to eq(memory.headers)
    end
  end

  it 'preserves PNG bytes and headers, including each call site’s filename policy' do
    Tempfile.create(['page', '.png']) do |file|
      file.binmode
      file.write(bytes)
      file.flush
      image = double('page image', attached?: true, download: bytes)
      allow(Disclosures::Blobs).to receive(:local_path).with(image).
        and_return(file.path)
      local = send_from(Disclosures::BaseController, :send_png, image)
      managed = send_from(AttachmentManagement::BaseController, :send_png,
                          Pathname.new(file.path))
      allow(Disclosures::Blobs).to receive(:local_path).with(image).
        and_return(nil)
      memory = send_from(Disclosures::BaseController, :send_png, image)

      [local, managed, memory].each do |response|
        expect(response.body.b).to eq(bytes)
        expect(response.headers['Content-Type']).to eq('image/png')
        expect(response.headers['Content-Security-Policy']).to be_nil
      end
      expect(local.headers).to eq(memory.headers)
      expect(local.headers.except('Content-Disposition')).
        to eq(managed.headers.except('Content-Disposition'))
      expect(local.headers['Content-Disposition']).to eq('inline')
      expect(managed.headers['Content-Disposition']).
        to start_with('inline;').and include(File.basename(file.path))
    end
  end

  [nil, false].each do |attached|
    it "refuses a missing document page (#{attached.inspect})" do
      image = double('page image', attached?: attached) unless attached.nil?
      expect do
        send_from(Disclosures::BaseController, :send_png, image)
      end.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
