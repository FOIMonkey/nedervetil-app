module Disclosures
  # Reads page images via local Tesseract (IncomingAttention::Outcome::Ocr),
  # correcting orientation/tilt and keeping the single strongest reading.
  # See doc/FORK.md.
  module Ocr
    LONG_SIDE = 2_500
    # Below this the orientation check is a guess.
    SURE_OF_TURN = 2
    # Degrees; rotating by less than this only blurs the image.
    SMALL_TILT = 0.5
    # Large tilts are under-measured at first and can flip sign.
    LARGE_TILT = 3
    # Mean word confidence below this is noise.
    SOUND_CONFIDENCE = 60
    # Fewer words than this cannot prove page orientation.
    WEAK_WORDS = 30
    MAX_OUTPUT = 2.megabytes
    ENVIRONMENT = { 'OMP_THREAD_LIMIT' => '1' }.freeze
    TSV_HEADER = "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\t".
                 freeze

    # text: what Tesseract read; confidences: of each word, 0 to 100.
    Reading = Struct.new(:text, :confidences) do
      def strength
        confidences.sum / 100.0
      end

      def sound?
        confidences.any? &&
          confidences.sum / confidences.size >= SOUND_CONFIDENCE
      end

      def weak?
        !sound? || confidences.size < WEAK_WORDS
      end

      def blank?
        confidences.empty?
      end
    end

    module_function

    # job: AlaveteliSandbox job holding pdf_path and dir, or nil.
    def pdf_page(pdf_path, page, dir, job:)
      prefix = File.join(dir, "ocr-#{page}")
      runner.limited('pdftoppm', '-cropbox', '-f', page.to_s, '-l', page.to_s,
                     '-scale-to', LONG_SIDE.to_s, '-gray', '-png',
                     '-singlefile', pdf_path, prefix,
                     job: job, binary_output: true) or return nil
      image("#{prefix}.png", job: job)
    end

    # Only for PNGs made by pdf_page, never untrusted files. Nil if unreadable.
    def image(png_path, job:)
      return nil unless File.exist?(png_path)

      best(png_path, job)&.text
    end

    # Always reads as-is; prefers a sound turned reading with higher strength.
    # Tries other quarters only if unsure and non-blank (blank stays blank).
    def best(png, job)
      turn, sure = quarter_turn(png, job)
      tilt = tilt_after(png, turn, job)
      turned = []
      turned << reading(png, turn + tilt, job) unless (turn + tilt).zero?
      turned << reading(png, turn - tilt, job) if tilt.abs > LARGE_TILT
      best = strongest(reading(png, 0, job), turned.compact.select(&:sound?))
      return best if sure || best&.blank? || (best && !best.weak?)

      guesses = [90, 180, 270].map { |quarter| reading(png, quarter, job) }
      strongest(best, guesses.compact.reject(&:weak?))
    end

    def strongest(first, others)
      [first, *others].compact.max_by(&:strength)
    end

    # Clockwise quarter turn and confidence flag; fails on sparse pages.
    def quarter_turn(png, job)
      found = utf8(runner.limited('tesseract', png, '-', '--psm', '0',
                                  job: job, env: ENVIRONMENT))
      turn = found[/^Rotate: (\d+)$/, 1].to_i
      sure = found[/^Orientation confidence: ([\d.]+)$/, 1].to_f >=
             SURE_OF_TURN
      sure && [90, 180, 270].include?(turn) ? [turn, true] : [0, sure]
    end

    def tilt_after(png, turn, job)
      tilt = measured_tilt(png, turn, job)
      tilt += measured_tilt(png, turn + tilt, job) if tilt.abs > LARGE_TILT
      tilt.abs < SMALL_TILT ? 0 : tilt.round(2)
    rescue AttachmentManagement::Command::Failed
      0
    end

    def measured_tilt(png, turned_by, job)
      utf8(magick(png, '-resize', '50%', '-background', 'white',
                  '-rotate', turned_by.to_s, '-deskew', '40%',
                  '-format', '%[deskew:angle]', 'info:', job: job)).to_f
    end

    # Cleans up intermediates each call because multi-page docs share one job.
    def reading(png, degrees, job)
      image = png
      unless degrees.zero?
        image = "#{png.delete_suffix('.png')}-turned.png"
        magick(png, '-background', 'white', '-rotate', degrees.to_s,
               '+repage', image, job: job)
      end
      base = image.delete_suffix('.png')
      runner.limited('tesseract', image, base, 'txt', 'tsv',
                     job: job, env: ENVIRONMENT) or return nil
      Reading.new(utf8(output("#{base}.txt", job)),
                  confidences(utf8(output("#{base}.tsv", job))))
    rescue AttachmentManagement::Command::Failed
      nil
    ensure
      FileUtils.rm_f(["#{base}.txt", "#{base}.tsv"]) if base
      FileUtils.rm_f(image) unless image == png
    end

    def confidences(tsv)
      rows = tsv.lines
      return [] unless rows.shift.to_s.start_with?(TSV_HEADER)

      rows.filter_map do |row|
        fields = row.chomp.split("\t", 12)
        next unless fields[0] == '5' && fields[11].to_s.strip.present?

        Float(fields[10], exception: false)&.clamp(0, 100)
      end
    end

    def output(path, job)
      AttachmentManagement.read_output(path, job: job, max: MAX_OUTPUT)
    end

    def magick(*args, job:)
      AttachmentManagement::Command.run('magick', *Renderer::MAGICK_LIMITS,
                                        *args, job: job, timeout: 60)
    end

    def utf8(bytes)
      bytes.to_s.dup.force_encoding('UTF-8').scrub('')
    end

    def runner
      IncomingAttention::Outcome::Ocr
    end
  end
end
