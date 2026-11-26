require 'spec_helper'

# In-process and stubbed-job specs; real jobs are covered in
# spec/integration/mail_worker_spec.rb.
RSpec.describe MailHandler::Reading do
  include MailReadingComparison

  fixtures = Dir[Rails.root.join('spec/fixtures/files/*.eml')]

  def fixture(name)
    File.binread(Rails.root.join('spec/fixtures/files', name))
  end

  describe '.of' do
    fixtures.each do |path|
      name = File.basename(path)

      it "gives what the walk gives for #{name}" do
        raw = File.binread(path)
        expect_reading_to_equal_walk(described_class.of(raw), raw)
      end

      it "finds the last part of #{name} from its stored bytes" do
        raw = File.binread(path)
        stored = walked(raw)[:parts].last[:body].b

        matched = described_class.of(raw, stored: stored).matched
        expect(MailHandler.calculate_hexdigest(matched[:body])).
          to eq(MailHandler.calculate_hexdigest(stored))
        expect(matched[:hexdigest]).to eq(Digest::MD5.hexdigest(matched[:body]))
      end

      it "hands back one part of #{name} when only that is asked for" do
        raw = File.binread(path)
        parts = walked(raw)[:parts]
        digest = parts.last[:hexdigest]
        first = parts.find { |part| part[:hexdigest] == digest }

        reading = described_class.of(raw, part: digest)
        expect(exactly(reading.part_with(digest).attributes)).
          to eq(exactly(first))
        expect(reading.parts.count(&:body)).to eq(1)
        described = reading.parts.map { |part| part.attributes.except(:body) }
        expect(exactly(described)).
          to eq(exactly(parts.map { |part| part.except(:body) }))
      end
    end

    it 'hands back no part’s bytes when none are asked for' do
      raw = fixture('incoming-request-two-same-name.eml')
      reading = described_class.of(raw, bodies: false)

      expect(reading.parts.map(&:content_type)).
        to eq(walked(raw)[:parts].map { |part| part[:content_type] })
      expect(reading.parts.map(&:body)).to all(be_nil)
      expect(reading.parts.map(&:uuencoded)).to all(be_nil)
    end

    it 'has no part for a digest the mail does not hold' do
      raw = fixture('incoming-request-two-same-name.eml')
      reading = described_class.of(raw, part: '0' * 32)

      expect(reading.part_with('0' * 32)).to be_nil
      expect(reading.parts.map(&:body)).to all(be_nil)
    end

    it 'raises TooComplex for a mail past the part limits, as the walk ' \
       'does' do
      inner = "Content-Type: text/plain\r\n\r\ninner\r\n"
      (MailHandler::MAX_PART_DEPTH + 1).times do
        inner = "Content-Type: message/rfc822\r\n\r\n#{inner}"
      end
      raw = "From: a@example.com\r\nSubject: nested\r\n#{inner}"

      expect(walked(raw)).to be_a(MailHandler::TooComplex)
      expect { described_class.of(raw) }.
        to raise_error(MailHandler::TooComplex, walked(raw).message)
    end

    it 'reads the source as bytes, whatever its encoding says' do
      raw = "Subject: s\r\nContent-Type: text/plain; charset=utf-7\r\n\r\n" \
            "Hi Mom -+Jjo--!\r\n"
      expect(raw.encoding).to eq(Encoding::UTF_8)

      expect(exactly(read(described_class.of(raw)))).
        to eq(exactly(walked(raw.b)))
      expect(exactly(walked(raw))).not_to eq(exactly(walked(raw.b)))
    end

    it 'lets a refused read of an attached file through' do
      allow(AlaveteliSandbox).to receive(:job).
        and_raise(AlaveteliSandbox::Refused, 'no sandbox')

      expect { described_class.of(fixture('tnef-attachment-empty.eml')) }.
        to raise_error(MailHandler::ReadRefused, /tnef could not run/)
    end

    it 'handles invalid UTF-8 in uuencode scanning, unknown transfer ' \
       'encodings and binary attached message bodies' do
      bad_utf8 = "begin 644 a.txt\n\xFF\xFE\n`\nend\n".
                 dup.force_encoding('UTF-8')
      expect(MailHandler.uuencoded_ranges(bad_utf8)).to be_an(Array)

      unknown_cte = "From: a@example.com\r\nContent-Type: text/plain\r\n" \
                    "Content-Transfer-Encoding: quoted-p\r\n\r\nHello\r\n"
      expect(described_class.of(unknown_cte).parts.first.body).
        to include('Hello')

      attached_bin = "From: a@example.com\r\nMIME-Version: 1.0\r\n" \
                     "Content-Type: message/rfc822\r\n\r\n" \
                     "From: b@example.com\r\nSubject: Hi\r\n" \
                     "Content-Type: text/plain; charset=bogus-xyz\r\n\r\n" \
                     "\x80\x81\x82\r\n".b
      expect(described_class.of(attached_bin).parts.first.body).
        to include('From:')

      attached_bad_cte = "From: a@example.com\r\nMIME-Version: 1.0\r\n" \
                         "Content-Type: message/rfc822\r\n" \
                         "Content-Transfer-Encoding: se64\r\n\r\n" \
                         "From: b@example.com\r\nSubject: Hi\r\n\r\nBody\r\n"
      expect(described_class.of(attached_bad_cte).parts.first.body).
        to include('Body')
    end
  end

  describe 'a stored file to find the original of' do
    def matched(raw, stored)
      described_class.of(raw, stored: stored).matched
    end

    it 'is not looked for unless one is given' do
      expect(described_class.of(fixture('incoming-request-plain.eml')).
               matched).to be_nil
    end

    it 'is found by its bytes, and only that part is handed back' do
      raw = fixture('incoming-request-two-same-name.eml')
      last = walked(raw)[:parts].last
      reading = described_class.of(raw, stored: last[:body].b)

      expect(exactly(reading.matched)).to eq(exactly(last))
      expect(reading.parts.count(&:body)).to eq(1)
    end

    it 'is found when header lines were added above it' do
      raw = fixture('incoming-request-two-same-name.eml')
      last = walked(raw)[:parts].last

      expect(exactly(matched(raw, "X-Added: yes\n\n#{last[:body].b}"))).
        to eq(exactly(last))
    end

    it 'is found when its line ends and trailing space differ' do
      raw = fixture('incoming-request-plain.eml')
      part = walked(raw)[:parts].first
      expect(part[:body]).to include("\n")
      stored = "#{part[:body].gsub("\n", "\r\n")}   \r\n"

      expect(exactly(matched(raw, stored))).to eq(exactly(part))
    end

    it 'is found among the uuencoded blocks of the plain-text parts' do
      %w[simple-uuencoded-attachment.eml inline-uuencode.eml
         incoming-request-bad-uuencoding.eml].each do |name|
        raw = fixture(name)
        walk = walked(raw)
        index = walk[:blocks].index(&:any?)
        block = walk[:blocks][index].first

        found = matched(raw, block[:body])
        expect(found.except(:filename)).to eq(
          block.except(:filename).merge(
            url_part_number: walk[:parts][index][:url_part_number] + 1
          )
        )
        expect(found[:filename]).to eq(block[:filename])
        expect(found[:filename].encoding).to eq(Encoding::UTF_8)
      end
    end

    it 'is not found when the email holds nothing like it' do
      raw = fixture('incoming-request-plain.eml')
      reading = described_class.of(raw, stored: 'nothing like any part')

      expect(reading.matched).to be_nil
      expect(reading.parts.map(&:body)).to all(be_nil)
    end
  end

  describe 'a stored file that differs from its part in small ways' do
    let(:mail) do
      mail_attachment = Mail.new(
        <<~EML
          Subject: Attached email

          Hello world
        EML
      ).to_s

      mail_with_uuencoded = Mail.new(
        <<~EML
          Subject: Cat

          Hi Cat!

          begin 644 cat.txt
          (0V%T#0I#870`
          `
          end
        EML
      ).to_s

      Mail.new do
        add_file filename: 'crlf.txt', content: "foo\r\nfoo"
        add_file filename: 'lf.txt', content: "bar\nbar"
        add_file filename: 'crlf-non-ascii.txt', content: "Aberdâr\r\n"
        add_file filename: 'lf-non-ascii.txt', content: "Aberdâr\n"
        add_file filename: 'latin1.txt', content: "naïve"
        add_file filename: 'mail.eml', content: mail_attachment
        add_file filename: 'uuencoded.eml', content: mail_with_uuencoded
      end
    end

    subject(:attributes) do
      described_class.of(mail.to_s, stored: body).matched
    end

    context 'when body has LF line ending' do
      let(:body) { "foo\nfoo" }
      it { is_expected.to include(body: "foo\nfoo") }
    end

    context 'when body has CRLF line ending' do
      let(:body) { "bar\r\nbar" }
      it { is_expected.to include(body: "bar\nbar") }
    end

    context 'when binary body has LF line endings and non ASCII characters' do
      let(:body) { "Aberdâr\n".b }
      it { is_expected.to include(body: "Aberdâr\n") }
    end

    context 'when binary body has CRLF line endings and non ASCII characters' do
      let(:body) { "Aberdâr\r\n".b }
      it { is_expected.to include(body: "Aberdâr\n") }
    end

    context 'when binary body encoded as Latin 1 / ISO-8859-1' do
      let(:body) { "na\xEFve".b }
      it { is_expected.to include(body: "naïve") }
    end

    context 'when attached email headers are different' do
      let(:body) do
        <<~EML
          Subject: A different subject

          Hello world
        EML
      end

      it 'is the attached email’s text' do
        expect(attributes).to include(within_rfc822_subject: 'Attached email')
        expect(attributes[:body]).to end_with("Hello world\n")
      end
    end

    context 'when body has trailing whitespace' do
      let(:body) { "bar\nbar\n" }
      it { is_expected.to include(body: "bar\nbar") }
    end

    context 'when body has been uuencoded' do
      let(:body) { "Cat\nCat" }
      it { is_expected.to include(body: "Cat\r\nCat") }
    end

    context 'when body does not match' do
      let(:body) { 'this does not match' }
      it { is_expected.to eq(nil) }
    end
  end

  describe 'a part asked for by its digest' do
    let(:mail) do
      Mail.new do
        add_file filename: 'file.txt', content: 'hereisthetext'
      end
    end

    it 'is handed back with its attributes' do
      hexdigest = Digest::MD5.hexdigest('hereisthetext')
      part = described_class.of(mail.to_s, part: hexdigest).
             part_with(hexdigest)

      expect(part.attributes).to include(
        body: 'hereisthetext', filename: 'file.txt', hexdigest: hexdigest
      )
    end

    it 'is not there for a digest the mail does not hold' do
      expect(described_class.of(mail.to_s, part: 'incorrect').
               part_with('incorrect')).to be_nil
    end
  end

  describe 'a report and files that are not what the worker is meant to ' \
           'leave' do
    let(:raw) { fixture('simple-uuencoded-attachment.eml') }
    let(:built) { MailHandler::Report.build(raw) }
    let(:report) { JSON.parse(JSON.generate(built.first)) }
    let(:files) { built.last.transform_values(&:b) }

    def reading(report, files, stored: false)
      described_class.new(report, stored: stored) do |name, _size|
        files.fetch(name)
      end
    end

    it 'are taken when they are as built' do
      expect(reading(report, files).parts.size).to eq(1)
      expect(reading(report, files).parts.first.uuencoded.size).to eq(1)
    end

    it 'are taken when a part is empty, and read as a frozen string' do
      empty, = MailHandler::Report.build(
        fixture('incoming-request-empty.eml'), stored: nil
      )
      empty = JSON.parse(JSON.generate(empty))
      expect(empty['parts'][0]['body']['bytes']).to eq(0)

      read = described_class.new(empty) { |_name, _size| ''.freeze }
      expect(read.parts.first.body).to eq('')
      expect(read.parts.first.body.encoding.name).
        to eq(empty['parts'][0]['body']['encoding'])
    end

    it 'are refused when a part’s bytes do not have its digest' do
      files['part-0'] = files['part-0'].sub('a', 'b')
      expect { reading(report, files) }.
        to raise_error(described_class::Invalid, /part-0 is not the part/)
    end

    it 'are refused when a uuencoded block’s bytes do not have its digest' do
      files['uu-0-0'] = "#{files['uu-0-0']}x"
      report['parts'][0]['uuencoded'][0]['body']['bytes'] += 1
      expect { reading(report, files) }.
        to raise_error(described_class::Invalid, /uu-0-0 is not the part/)
    end

    it 'are refused when a part is not as long as the report says' do
      report['parts'][0]['body']['bytes'] -= 1
      expect { reading(report, files) }.
        to raise_error(described_class::Invalid, /part-0 is not the part/)
    end

    it 'are refused when a part’s file is missing' do
      files.delete('part-0')
      expect { reading(report, files) }.
        to raise_error(described_class::Invalid)
    end

    it 'are refused when a digest is not a digest' do
      report['parts'][0]['hexdigest'] = { 'text' => '../../etc/passwd',
                                          'encoding' => 'UTF-8' }
      expect { reading(report, files) }.
        to raise_error(described_class::Invalid, /no content type or digest/)
    end

    it 'are refused when a field is not text' do
      report['parts'][0]['filename'] = ['a']
      expect { reading(report, files) }.
        to raise_error(described_class::Invalid, /filename/)
    end

    it 'are refused when an encoding is not one Ruby has' do
      report['parts'][0]['body']['encoding'] = 'KLINGON'
      expect { reading(report, files) }.
        to raise_error(described_class::Invalid)
    end

    it 'are refused when there are more parts than the walk allows' do
      report['parts'] *= MailHandler::MAX_PARTS + 1
      expect { reading(report, files) }.
        to raise_error(described_class::Invalid, /a list/)
    end

    it 'are refused when the report is not an object' do
      expect { reading([], files) }.
        to raise_error(described_class::Invalid, /not an object/)
    end

    it 'are refused when the matched part is not one of the parts' do
      report['matched'] = { 'part' => 7 }
      expect { reading(report, files, stored: true) }.
        to raise_error(described_class::Invalid)
    end

    it 'have what they say matched ignored when no stored file was given' do
      report['matched'] = { 'part' => 0 }
      expect(reading(report, files).matched).to be_nil
      expect(reading(report, files, stored: true).matched).
        to include(body: files['part-0'])
    end

    it 'are refused, with nothing read, when a part is said to be larger ' \
       'than the worker can write' do
      limit = AlaveteliSandbox::MailStep::LIMITS[:file_size]
      report['parts'][0]['body']['bytes'] = limit + 1
      read = []
      expect do
        described_class.new(report) do |name, _size|
          read << name
          files.fetch(name)
        end
      end.to raise_error(described_class::Invalid, /larger than a part/)
      expect(read).to be_empty
    end

    it 'are refused when a size is too large to be a size at all' do
      report['parts'][0]['body']['bytes'] = 10**30
      expect { reading(report, files) }.
        to raise_error(described_class::Invalid)
    end

    it 'are refused when a part’s number is not one a part can have' do
      [-1, MailHandler::MAX_PARTS + MailHandler::MAX_UU_BLOCKS + 2,
       2**70].each do |number|
        report['parts'][0]['url_part_number'] = number
        expect { reading(report, files) }.
          to raise_error(described_class::Invalid, /url_part_number/)
      end
    end

    it 'are refused when uuencoded attachments are numbered from past ' \
       'what the walk allows' do
      report['count_first_uudecode_count'] = 2**40
      expect { reading(report, files) }.
        to raise_error(described_class::Invalid, /a number/)
    end

    it 'are refused when an encoding is one that ordinary string methods ' \
       'raise in' do
      %w[UTF-16 UTF-16LE UTF-7 ISO-2022-JP].each do |name|
        report['parts'][0]['filename'] = { 'text' => 'a', 'encoding' => name }
        expect { reading(report, files) }.
          to raise_error(described_class::Invalid)
      end
    end

    it 'are refused when a string is packed two ways at once, or as ' \
       'something that is not a string' do
      [{ 'text' => 'a', 'base64' => 'YQ==', 'encoding' => 'UTF-8' },
       { 'text' => 7, 'encoding' => 'UTF-8' },
       { 'encoding' => 'UTF-8' }].each do |packed|
        report['parts'][0]['filename'] = packed
        expect { reading(report, files) }.
          to raise_error(described_class::Invalid)
      end
    end

    it 'are refused when a part was searched for uuencoded blocks after ' \
       'the mail had reached the limit' do
      block = report['parts'][0]['uuencoded'][0]
      full = report['parts'][0].merge(
        'uuencoded' => [block] * MailHandler::MAX_UU_BLOCKS
      )
      files.merge!(
        (0...MailHandler::MAX_UU_BLOCKS).to_h do |number|
          ["uu-0-#{number}", files['uu-0-0']]
        end,
        'part-1' => files['part-0'], 'part-2' => files['part-0']
      )

      report['parts'] = [full, report['parts'][0].merge('uuencoded' => nil)]
      expect(reading(report, files).parts.last.uuencoded).to be_nil

      report['parts'] = [full, report['parts'][1].merge('uuencoded' => [])]
      expect { reading(report, files) }.
        to raise_error(described_class::Invalid, /past the limit/)
    end

    it 'keep only the start of the reason a mail was past the limits' do
      read = reading({ 'too_complex' => 'x' * 5000 }, files)
      expect(read.too_complex.size).to eq(300)
    end

    it 'keep only the start of the reason a tool failed' do
      report['unexpanded'] = [{ 'program' => 'tnef', 'reason' => 'x' * 5000 }]
      expect(reading(report, files).unexpanded).to eq([['tnef', 'x' * 300]])
    end

    it 'refuses reports whose cumulative part bytes exceed MAX_TOTAL_BYTES' do
      stub_const("#{described_class}::MAX_TOTAL_BYTES",
                 files['part-0'].bytesize)
      report['parts'] = [report['parts'][0].merge('uuencoded' => nil),
                         report['parts'][0].merge('uuencoded' => nil)]
      files['part-1'] = files['part-0']
      read = []
      expect do
        described_class.new(report) do |name, _size|
          read << name
          files.fetch(name)
        end
      end.to raise_error(described_class::Invalid, /larger than allowed/)
      expect(read).to eq(['part-0'])
    end
  end

  describe 'with the sandbox required' do
    let(:raw) { fixture('tnef-attachment-truncated.eml') }
    let(:dir) { Dir.mktmpdir('reading-spec') }
    let(:job) { instance_double(AlaveteliSandbox::Job) }
    let(:steps) { [] }
    # Built eagerly before Report.build is disallowed in before.
    let!(:left) do
      report, files = MailHandler::Report.build(raw, stored: nil)
      report['unexpanded'] = [{ 'program' => 'tnef', 'reason' => 'no good' }]
      files.merge('report.json' => JSON.generate(report))
    end

    before do
      allow(AlaveteliConfiguration).
        to receive(:sandbox_converters).and_return('required')
      allow(AlaveteliSandbox).to receive(:job) do |**options, &block|
        steps << options
        block.call(job)
      end
      allow(job).to receive(:scratch) { |name| File.join(dir, name) }
      allow(job).to receive(:run_mail_read) do |**options|
        steps << options
        left.each { |name, bytes| File.binwrite(File.join(dir, name), bytes) }
      end
      # Mirrors Job#read: missing files raise Errno::ENOENT.
      allow(job).to receive(:read) do |name, max:|
        bytes = File.binread(File.join(dir, name))
        if bytes.bytesize > max
          raise AlaveteliSandbox::LimitExceeded, "#{name} is too large"
        end

        bytes
      end
      allow(Rails.logger).to receive(:warn)
      expect(MailHandler::Report).not_to receive(:build)
    end

    after { FileUtils.remove_entry(dir) }

    it 'has the worker read the mail, as a job’s step, and takes what it ' \
       'left' do
      reading = described_class.of(raw)

      expect(steps).to eq(
        [{ input: raw, input_name: 'mail.eml',
           output_files: described_class::OUTPUT_FILES },
         { bodies: 'all', stored: false }]
      )
      expect(reading.parts.map(&:hexdigest)).
        to eq(JSON.parse(left['report.json'])['parts'].
              map { |part| part['hexdigest']['text'] })
      expect(reading.parts.map { |part| part.body.b }).
        to eq(left.values_at('part-0', 'part-1').map(&:b))
    end

    it 'allows a read every file a report may name: a thousand parts, ' \
       'and the blocks of a search that stops at the limit' do
      expect(described_class::OUTPUT_FILES).to eq(
        MailHandler::MAX_PARTS + (2 * MailHandler::MAX_UU_BLOCKS) + 3
      )
    end

    it 'gives the worker a stored file to match, in the scratch area' do
      described_class.of(raw, stored: 'stored bytes')

      expect(steps.last).to eq(bodies: 'none', stored: true)
      expect(File.binread(File.join(dir, 'stored'))).to eq('stored bytes')
    end

    it 'asks the worker for one part’s bytes, and reads only that file' do
      digest = JSON.parse(left['report.json'])['parts'][1]['hexdigest']['text']
      left.delete('part-0')

      reading = described_class.of(raw, part: digest)

      expect(steps.last).to eq(bodies: digest, stored: false)
      expect(reading.part_with(digest).body.b).to eq(left['part-1'].b)
      expect(reading.parts.first.body).to be_nil
    end

    it 'asks the worker for no bytes when given a digest that isn’t one' do
      reading = described_class.of(raw, part: '../etc/passwd')

      expect(steps.last).to eq(bodies: 'none', stored: false)
      expect(reading.part_with('../etc/passwd')).to be_nil
    end

    it 'asks the worker for no bytes, and reads no part’s file' do
      left.delete('part-0')
      left.delete('part-1')

      reading = described_class.of(raw, bodies: false)

      expect(steps.last).to eq(bodies: 'none', stored: false)
      expect(reading.parts.map(&:body)).to eq([nil, nil])
    end

    it 'logs why an attached file was left as it came, as a failed step ' \
       'is logged' do
      described_class.of(raw)
      expect(Rails.logger).to have_received(:warn).
        with(/\[sandbox\] failed program=tnef .*detail=no good/)
    end

    def for_a_page(&)
      controller = instance_double(ApplicationController, request: nil)
      ActiveSupport::ExecutionContext.set(controller: controller, &)
    end

    def reads_asked_for
      steps.select { |step| step.key?(:bodies) }
    end

    it 'gives a job’s read the worker’s own time' do
      described_class.of(raw)
      expect(reads_asked_for).to eq([{ bodies: 'all', stored: false }])
    end

    it 'gives a page’s read fifteen seconds, whatever else runs inside ' \
       'the request' do
      for_a_page do
        ActiveSupport::ExecutionContext.set(job: Object.new) do
          described_class.of(raw)
        end
      end

      expect(reads_asked_for).to eq(
        [{ bodies: 'all', stored: false, timeout: 15 }]
      )
    end

    describe 'a page’s time for reads' do
      let(:time) { [1000.0] }

      before do
        Current.reset
        allow(described_class).to receive(:clock) { time.first }
        allow(job).to receive(:run_mail_read) do |**options|
          time[0] += 6
          steps << options
          left.each do |name, bytes|
            File.binwrite(File.join(dir, name), bytes)
          end
        end
      end

      after { Current.reset }

      def times_given
        reads_asked_for.map { |read| read[:timeout] }
      end

      it 'is fifteen seconds for all of them together: each has what is ' \
         'left' do
        for_a_page { 3.times { described_class.of(raw) } }

        expect(times_given).to eq([15, 9, 3])
      end

      it 'counts the time its reads take, not the time between them' do
        for_a_page do
          3.times do
            described_class.of(raw)
            time[0] += 100
          end
        end

        expect(times_given).to eq([15, 9, 3])
      end

      it 'refuses a read once it is spent, and asks the worker for nothing' do
        for_a_page do
          3.times { described_class.of(raw) }
          expect { described_class.of(raw) }.to raise_error(
            MailHandler::ReadRefused, /spent its time for reading mail/
          )
          expect { described_class.page_seconds_left! }.
            to raise_error(MailHandler::ReadRefused)
        end

        expect(times_given).to eq([15, 9, 3])
      end

      it 'counts the time a refused read took' do
        allow(job).to receive(:run_mail_read) do
          time[0] += 6
          raise AlaveteliSandbox::Refused, 'the cell is unavailable'
        end

        for_a_page do
          expect { described_class.of(raw) }.
            to raise_error(MailHandler::ReadRefused)
          expect(Current.mail_read_left).to eq(9.0)
        end
      end

      it 'is not counted for a job, or for a read in this process' do
        expect(described_class.page_seconds_left!).to be_nil
        allow(AlaveteliSandbox).to receive(:required?).and_return(false)
        for_a_page { expect(described_class.page_seconds_left!).to be_nil }
      end

      it 'is given afresh to the self-test' do
        for_a_page do
          3.times { described_class.of(raw) }
          expect { described_class.self_test }.to raise_error(
            MailHandler::ReadRefused, /not read as expected/
          )
        end

        expect(times_given).to eq([15, 9, 3, 15])
      end
    end

    describe 'once a read has been refused' do
      before do
        Current.reset
        allow(job).to receive(:run_mail_read) do |**options|
          steps << options
          raise AlaveteliSandbox::Refused, 'the cell is unavailable'
        end
      end

      after { Current.reset }

      it 'asks for no more for the same page' do
        for_a_page do
          2.times do
            expect { described_class.of(raw) }.
              to raise_error(MailHandler::ReadRefused)
          end
        end

        expect(reads_asked_for.size).to eq(1)
      end

      it 'asks again for the next page' do
        2.times do
          for_a_page do
            expect { described_class.of(raw) }.
              to raise_error(MailHandler::ReadRefused)
          end
          Current.reset
        end

        expect(reads_asked_for.size).to eq(2)
      end

      it 'is still asked by the self-test, which says why it was refused' do
        for_a_page do
          expect { described_class.of(raw) }.
            to raise_error(MailHandler::ReadRefused)
          expect { described_class.self_test }.to raise_error(
            MailHandler::ReadRefused, /the cell is unavailable/
          )
        end

        expect(reads_asked_for.size).to eq(2)
      end

      it 'goes on asking in a job' do
        2.times do
          expect { described_class.of(raw) }.
            to raise_error(MailHandler::ReadRefused)
        end

        expect(reads_asked_for.size).to eq(2)
      end
    end

    [AlaveteliSandbox::Refused, AlaveteliSandbox::TimedOut,
     AlaveteliSandbox::LimitExceeded].each do |error|
      it "refuses the read when the step raises #{error.name.demodulize}" do
        allow(job).to receive(:run_mail_read).and_raise(error, 'why')

        expect { described_class.of(raw) }.to raise_error(
          MailHandler::ReadRefused,
          /could not run: #{error.name.demodulize}: why/
        )
      end
    end

    it 'refuses the read when the worker fails, with what it said first' do
      result = AlaveteliSandbox::ProcessRunner::Result.new(
        stderr: "NotLoaded: LoadError: no mail\nmore\n"
      )
      allow(job).to receive(:run_mail_read).and_raise(
        AlaveteliSandbox::Failed.new('mail-worker failed (exit 2)', result)
      )

      expect { described_class.of(raw) }.to raise_error(
        MailHandler::ReadRefused,
        'the mail worker failed: NotLoaded: LoadError: no mail'
      )
    end

    it 'refuses the read when the worker left no report' do
      left.delete('report.json')

      expect { described_class.of(raw) }.to raise_error(
        MailHandler::ReadRefused, /files can't be used: No such file/
      )
    end

    it 'refuses the read when a part’s file is not there' do
      left.delete('part-1')

      expect { described_class.of(raw) }.to raise_error(
        MailHandler::ReadRefused, /files can't be used: No such file/
      )
    end

    it 'refuses the read when the stored file can’t be written' do
      allow(File).to receive(:binwrite).and_call_original
      allow(File).to receive(:binwrite).
        with(File.join(dir, 'stored'), 'stored bytes').
        and_raise(Errno::ENOSPC)

      expect { described_class.of(raw, stored: 'stored bytes') }.
        to raise_error(MailHandler::ReadRefused, /No space left/)
    end

    it 'refuses the read when the report names a program that is not one ' \
       'of the worker’s tools' do
      report = JSON.parse(left['report.json'])
      report['unexpanded'] = [{ 'program' => "x\n[sandbox] failed",
                                'reason' => 'forged' }]
      left['report.json'] = JSON.generate(report)

      expect { described_class.of(raw) }.to raise_error(
        MailHandler::ReadRefused, /program the worker does not run/
      )
    end

    it 'refuses the read when the report is not JSON' do
      left['report.json'] = 'parts: all of them'

      expect { described_class.of(raw) }.
        to raise_error(MailHandler::ReadRefused, /report can't be used/)
    end

    it 'refuses the read when a part is not the one the report describes' do
      left['part-1'] = "#{left['part-1'].b}x".b

      expect { described_class.of(raw) }.to raise_error(
        MailHandler::ReadRefused, /LimitExceeded: part-1 is too large/
      )
    end

    it 'refuses the read when a part’s bytes do not have its digest' do
      left['part-1'] = left['part-1'].b.reverse

      expect { described_class.of(raw) }.to raise_error(
        MailHandler::ReadRefused,
        /report can't be used: part-1 is not the part/
      )
    end

    it 'raises TooComplex when the worker reports a mail past the limits' do
      left.replace(
        'report.json' => JSON.generate('too_complex' => 'too many parts')
      )

      expect { described_class.of(raw) }.
        to raise_error(MailHandler::TooComplex, 'too many parts')
    end
  end
end
