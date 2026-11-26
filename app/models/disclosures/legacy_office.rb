require 'tmpdir'

module Disclosures
  # Sandboxed LibreOffice conversions for legacy OLE2 Office files (.doc, .xls).
  module LegacyOffice
    ConversionError = Class.new(Error::Refused)
    TARGETS = %w[xlsx docx].freeze
    TIMEOUT = 180
    MAX_OOXML_BYTES = 256.megabytes

    module_function

    # Converts a legacy Office file to OOXML (.xlsx or .docx). When job: is
    # given, writes the validated file into job.scratch and returns its path;
    # otherwise runs a sandbox job and returns the converted bytes.
    def to_ooxml(bytes, target:, extension:, job: nil, input_path: nil)
      target = target.to_s.downcase
      unless TARGETS.include?(target)
        raise ArgumentError, "unsupported target #{target.inspect}"
      end

      ext = clean_extension(extension)
      ensure_soffice!

      if job
        convert_to_ooxml_in_job(job, input_path || job.input, target, ext)
      else
        AttachmentManagement.sandboxed(
          input: bytes, input_name: "source.#{ext}"
        ) do |sandbox_job|
          path = convert_to_ooxml_in_job(sandbox_job, sandbox_job.input,
                                         target, ext)
          AttachmentManagement.read_output(path, job: sandbox_job,
                                                 max: MAX_OOXML_BYTES)
        end
      end
    rescue ZipGuard::Refused, ConversionError
      raise
    rescue AttachmentManagement::Command::Failed,
           AttachmentManagement::Unsupported,
           AlaveteliSandbox::Error, Zip::Error => e
      raise ConversionError,
            _('This file couldn’t be converted: {{reason}}',
              reason: e.message.to_s.lines.first.to_s.strip)
    end

    def to_pdf(bytes, extension: '.doc', job: nil)
      ext = clean_extension(extension)
      ensure_soffice!

      if job
        convert_to_pdf_in_job(job, job.input, ext)
      else
        AttachmentManagement.sandboxed(
          input: bytes, input_name: "source.#{ext}"
        ) do |sandbox_job|
          convert_to_pdf_in_job(sandbox_job, sandbox_job.input, ext)
        end
      end
    rescue ConversionError
      raise
    rescue AttachmentManagement::Command::Failed,
           AttachmentManagement::Unsupported,
           AlaveteliSandbox::Error => e
      raise ConversionError,
            _('This file couldn’t be converted to PDF: {{reason}}',
              reason: e.message.to_s.lines.first.to_s.strip)
    end

    def convert_to_ooxml_in_job(job, input, target, ext)
      output = job.scratch("converted.#{target}")
      Dir.mktmpdir('office', job.scratch) do |dir|
        source = File.join(dir, "source.#{ext}")
        FileUtils.cp(input, source)
        AttachmentManagement::Command.run(
          'soffice', '--headless', '--norestore', '--nolockcheck',
          '--nodefault',
          "-env:UserInstallation=file://#{dir}/profile",
          '--convert-to', target,
          '--outdir', dir, source,
          job: job, timeout: TIMEOUT
        )
        converted = File.join(dir, "source.#{target}")
        unless File.exist?(converted)
          raise ConversionError, _('LibreOffice wrote no converted file.')
        end

        AttachmentManagement.copy_output(converted, job: job, to: output,
                                                    max: MAX_OOXML_BYTES)
      end
      OfficePackage::Isolated.read(%w[guard], path: output) do |read|
        ZipGuard.checked!(read, unpack: false)
      end
      output
    end

    def convert_to_pdf_in_job(job, input, ext)
      output = job.scratch('converted.pdf')
      Disclosures.engine(job: job).convert_to_pdf(input, ext, output)
      bytes = AttachmentManagement.read_output(
        output, job: job, max: Disclosures.max_bytes + 1
      )
      if bytes.bytesize > Disclosures.max_bytes
        raise ConversionError,
              _('The converted PDF is too large to publish.')
      end

      bytes
    end

    def ensure_soffice!
      return if AttachmentManagement::Command.available?('soffice')

      raise ConversionError,
            _('This file can’t be converted because LibreOffice is not ' \
              'available.')
    end

    def clean_extension(extension)
      ext = extension.to_s.downcase.delete_prefix('.')
      ext.match?(/\A[a-z0-9]{1,8}\z/) ? ext : 'bin'
    end
  end
end
