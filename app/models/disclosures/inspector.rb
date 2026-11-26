module Disclosures
  # Inspects PDFs for hidden content (annotations and incremental saves).
  # Office hidden content is handled by HiddenRisk; unsupported Office formats
  # report UNLISTED.
  module Inspector
    UNLISTED = 'Hidden content in this kind of file (OpenDocument, older ' \
               'Office or RTF) can’t be listed here.'.freeze
    # Max line length read from uncompressed PDF.
    LINE = 1.megabyte
    # pdftk's uncompressed copy of a PDF up to Disclosures.max_bytes.
    MAX_UNCOMPRESSED = 1.gigabyte
    ANNOTS = %r{/Annots\s*(?:\[([^\]]*)\]|(\d+)\s+\d+\s+R)}n
    REFERENCE = /\d+\s+\d+\s+R/n
    OBJECT = /\A\s*(\d+)\s+\d+\s+obj\b/n

    module_function

    # Uses pdftk uncompress so PDF 1.5 compressed object streams are scanned.
    def pdf(path, dir, job:)
      count = annotations(path, dir, job: job)
      if count.nil?
        return ['Annotations (comments, notes or links) couldn’t be ' \
                'checked in this PDF.']
      end
      return [] if count.zero?

      ["#{count} #{'annotation'.pluralize(count)} (comments, notes or links)"]
    end

    def annotations(path, dir, job:)
      out = File.join(dir, 'uncompressed.pdf')
      AttachmentManagement::Command.run('pdftk', path, 'output', out,
                                        'uncompress', job: job, timeout: 120)
      count = 0
      arrays = Set.new
      AttachmentManagement.open_output(out, job: job,
                                            max: MAX_UNCOMPRESSED) do |io|
        io.each_line("\n", LINE) do |line|
          line.scan(ANNOTS) do |list, reference|
            list ? count += list.scan(REFERENCE).size : arrays << reference.to_i
          end
        end
      end
      count + annotation_arrays(out, arrays, job: job)
    rescue AttachmentManagement::Command::Failed, SystemCallError
      nil
    ensure
      FileUtils.rm_f(out) if out
    end

    # Annotations in /Annots arrays kept as objects of their own.
    def annotation_arrays(path, numbers, job:)
      return 0 if numbers.empty?

      count = 0
      current = nil
      AttachmentManagement.open_output(path, job: job,
                                             max: MAX_UNCOMPRESSED) do |io|
        io.each_line("\n", LINE) do |line|
          current = Regexp.last_match(1).to_i if line =~ OBJECT
          unless numbers.include?(current) && (list = line[/\[([^\]]*)\]/n, 1])
            next
          end

          count += list.scan(REFERENCE).size
          numbers.delete(current)
        end
      end
      count
    end

    # An incremental save keeps the earlier version (and removed text) in the
    # file: one startxref and %%EOF per save. A linearised file starts with two.
    def pdf_hidden_text(path, job:)
      data = AttachmentManagement.read_output(path, job: job,
                                                    max: Disclosures.max_bytes)
      saves = [data.scan('%%EOF').size, data.scan('startxref').size].max
      saves -= 1 if data.byteslice(0, 1024).include?('/Linearized')
      if saves > 1
        ['An earlier saved version of the file, kept inside it (it can ' \
         'hold text since changed or removed)']
      else
        []
      end
    end
  end
end
