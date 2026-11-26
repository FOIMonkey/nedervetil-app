module AttachmentManagement
  # Processes a Revision working copy without modifying FoiAttachment#file.
  class Processor
    attr_reader :revision

    def initialize(revision, engine: nil, source_bytes: nil)
      @revision = revision
      @given_engine = engine
      @given_source_bytes = source_bytes
    end

    def run
      AttachmentManagement.sandboxed(input: source_bytes) do |job|
        @job = job
        @engine = @given_engine || AttachmentManagement.engine(job: job)
        output = job.scratch('output')
        type, filename, report = send(revision.kind, job.input, output)
        finish(output, type, filename, report)
      end
    rescue Unsupported => e
      fail_with(e.message)
    rescue Command::Failed, Boxes::Invalid, FoiAttachment::ErasedError,
           FoiAttachment::MissingError => e
      fail_with(PlainTextTranslation._('Processing failed: {{message}}',
                                       message: e.message))
    rescue ActiveStorage::FileNotFoundError
      fail_with(_('Processing failed: the draft’s file is no longer there.'))
    end

    private

    attr_reader :attachment, :job, :engine

    def source_bytes
      @attachment = revision.foi_attachment
      return @given_source_bytes if @given_source_bytes

      if revision.parent
        revision.parent.output_bytes
      elsif %w[pdf_redaction image_redaction office_pdf].include?(revision.kind)
        attachment.body
      else
        revision.output_bytes
      end
    end

    def pdf_redaction(input, output)
      report = engine.redact_pdf(input, revision.boxes, output)
      ['application/pdf', pdf_filename, report.merge(rasterized: true)]
    end

    def image_redaction(input, output)
      coder = engine.coder_for(revision.source_content_type) or
        raise Unsupported, :not_supported
      report = engine.redact_image(input, coder,
                                   revision.boxes.fetch(1, []), output)
      [revision.source_content_type, attachment.redacted_filename, report]
    end

    def office_pdf(input, output)
      zip = File.binread(input, 4) == "PK\x03\x04"
      sections = [*('guard_unpack' if zip), 'guard', 'inspector']
      findings = OfficePackage::Isolated.read(sections, path: input,
                                                        job: job) do |read|
        if zip
          begin
            ZipGuard.checked!(read, unpack: true)
          rescue ZipGuard::Refused => e
            raise Unsupported.new(:too_large, e.message[/\(.*\)/])
          end
        end
        OfficeInspector.findings_in(read)
      end
      report = engine.convert_to_pdf(
        input, extension_for(revision.source_content_type), output
      )
      ['application/pdf', pdf_filename, report.merge(office_findings: findings)]
    end

    def text_edit(input, output)
      text = File.binread(input).force_encoding('UTF-8')
      unless text.valid_encoding?
        raise Unsupported.new(:not_supported, _('the text is not valid UTF-8'))
      end

      sanitised = false
      if revision.source_content_type == 'text/html'
        text = attachment.sanitise_html(text)
        sanitised = true
      end
      File.binwrite(output, text)
      before = convert_string_to_utf8(attachment.body.dup, 'UTF-8').string
      report = { characters_before: before.size,
                 characters_after: text.size,
                 lines_changed: changed_lines(before, text),
                 html_sanitised: sanitised }
      [revision.source_content_type, attachment.redacted_filename, report]
    end

    def upload(input, output)
      FileUtils.cp(input, output)
      type = detected_type(input, revision.instructions['upload_filename'])
      report = { declared_type: revision.instructions['upload_content_type'],
                 detected_type: type }
      if type == 'text/html'
        html = File.binread(input).force_encoding('UTF-8').scrub
        File.binwrite(output, attachment.sanitise_html(html))
        report[:html_sanitised] = true
      end
      report[:pdf] = engine.inspect_pdf(output) if type == 'application/pdf'
      if ooxml?(type)
        report[:office_findings] = OfficeInspector.findings(output)
      end
      filename = if type == attachment.content_type
                   attachment.redacted_filename
                 else
                   renamed(type)
                 end
      [type, filename, report]
    end

    def finish(output, type, filename, report)
      bytes = AttachmentManagement.read_output(
        output, job: job, max: AttachmentManagement.max_bytes + 1
      )
      if bytes.bytesize > AttachmentManagement.max_bytes
        raise Unsupported, :too_large
      end

      sha = Digest::SHA256.hexdigest(bytes)
      revision.with_status_lock(%w[processing]) do
        revision.output.attach(io: StringIO.new(bytes), filename: filename,
                               content_type: type, identify: false)
        revision.update!(status: 'ready',
                         output_sha256: sha,
                         output_content_type: type,
                         output_filename: filename,
                         output_byte_size: bytes.bytesize,
                         report: report,
                         engine: engine.name,
                         error: nil)
      end
    end

    def fail_with(message)
      revision.with_status_lock(%w[processing]) do
        revision.output.purge if revision.output.attached?
        revision.update!(status: 'failed', error: message.truncate(1000))
      end
    end

    def pdf_filename
      renamed('application/pdf')
    end

    def renamed(type)
      base = attachment.redacted_filename.sub(/\.[A-Za-z0-9]{1,5}\z/, '')
      ext = AlaveteliFileTypes.mimetype_to_extension(type)
      ext ? "#{base}.#{ext}" : attachment.redacted_filename
    end

    def extension_for(type)
      ext = AlaveteliFileTypes.mimetype_to_extension(type) ||
            File.extname(attachment.filename).delete('.')
      ext.to_s.match?(/\A[A-Za-z0-9]{1,8}\z/) ? ext : 'bin'
    end

    def detected_type(path, filename)
      by_content = Marcel::MimeType.for(Pathname(path), name: filename.to_s)
      by_name = AlaveteliFileTypes.filename_to_mimetype(filename.to_s)
      type = by_content.presence || by_name
      type = by_name if by_name && type == 'application/octet-stream'
      type = 'image/jpeg' if type == 'image/pjpeg'
      type || 'application/octet-stream'
    end

    def ooxml?(type)
      type.to_s.start_with?('application/vnd.openxmlformats-officedocument')
    end

    def changed_lines(before, after)
      a = before.lines.map(&:rstrip).tally
      b = after.lines.map(&:rstrip).tally
      (a.keys | b.keys).sum { |line| (a.fetch(line, 0) - b.fetch(line, 0)).abs }
    end
  end
end
