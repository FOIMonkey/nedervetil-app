# frozen_string_literal: true

module PDFRedactor
  ##
  # Decodes the text of a QdfDoc's pages and matches the rules against it
  # (#run), then writes the censored file (#write). See PDFRedactor.
  class Redactor
    attr_reader :report, :rasterize

    M1 = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0].freeze
    # --deterministic-id: the file's /ID comes from its content, not the
    # clock, so the same file masked twice gives the same bytes.
    COMPRESS = %w[--object-streams=generate --compress-streams=y
                  --deterministic-id].freeze

    LABEL = '[redacted]'
    LABEL_FONT = 'RIRedacted'
    # Its width in Helvetica, in ems (ISO 32000-1 Annex D's standard widths).
    LABEL_EMS = 4.447
    MAX_FORM_PLACEMENTS = 10_000
    MAX_FORM_BOXES = 5_000
    UNSEEN_CHARS = "\u00AD\u200B\u200C\u200D\u2060\uFEFF"

    # PDFDocEncoding (Annex D) where it differs from Latin-1.
    PDFDOC = {
      0x18 => "˘", 0x19 => "ˇ", 0x1A => "ˆ", 0x1B => "˙", 0x1C => "˝",
      0x1D => "˛", 0x1E => "˚", 0x1F => "˜", 0x80 => "•", 0x81 => "†",
      0x82 => "‡", 0x83 => "…", 0x84 => "—", 0x85 => "–", 0x86 => "ƒ",
      0x87 => "⁄", 0x88 => "‹", 0x89 => "›", 0x8A => "−", 0x8B => "‰",
      0x8C => "„", 0x8D => "“", 0x8E => "”", 0x8F => "‘", 0x90 => "’",
      0x91 => "‚", 0x92 => "™", 0x93 => "ﬁ", 0x94 => "ﬂ", 0x95 => "Ł",
      0x96 => "Œ", 0x97 => "Š", 0x98 => "Ÿ", 0x99 => "Ž", 0x9A => "ı",
      0x9B => "ł", 0x9C => "œ", 0x9D => "š", 0x9E => "ž", 0xA0 => "€"
    }.freeze

    def initialize(doc, rules, depth: 0, input: nil, ocr: false)
      @doc = doc
      @rules = rules
      @depth = depth
      @input = input
      @ocr_asked = ocr
      @ocr = ocr && input && Ocr.available?
      @rasterize = []
      @ocr_queue = []
      @matched = Set.new.compare_by_identity # rules that matched anywhere
      @fonts = {}
      # stream object num -> { ops: { start => [stop, bytes] }, prefix:,
      # suffix: }
      @edits = {}
      @page_streams = Set.new
      @forms = {} # [form, resources] -> what it adds to a page that draws it
      @form_edits = {}
      @form_box_collector = nil
      @stream_balance = {}
      @running = Set.new # forms being read, as a form can draw itself
      @object_edits = [] # [start, stop, bytes]
      @labelled = [] # pages whose boxes say [redacted]
      @content_streams = [] # every content stream decoded, in order
      @groups = {} # first stream of a page -> all of the page's streams
      @report = Hash.new(0)
      @report['notes'] = []
      @pages = [] # what each page holds, for Survey
      # Parts of the file that go out as they came, and why (#leave).
      @report['unmasked_parts'] = []
    end

    # Per page, after #run: the glyphs that map to text and those that don't,
    # and the share of the page pictures cover (Survey).
    attr_reader :pages

    def run
      @doc.pages.each_with_index do |(page, res, attrs, ref), idx|
        @page = { images: 0, visible: 0, unmapped: 0, image_area: 0.0,
                  area: page_area(attrs), number: idx + 1,
                  image_boxes: [], extra_boxes: [] }
        contents = @doc.resolve(page['Contents'])
        sids = (contents.is_a?(Array) ? contents : [page['Contents']]).
               grep(Ref).select { |sid| @doc.object(sid.num)&.dig(:stream) }
        claim_page_streams(sids)
        collect_page_images(sids, res || {})
        run_streams(sids, res || {})
        if @page[:extra_boxes].any? && sids.any?
          add_boxes(sids.map(&:num), @page[:extra_boxes].uniq)
        end
        Array(@doc.resolve(page['Annots'])).each do |a|
          annot_streams(@doc.resolve(a), res || {})
        end
        apply_redact_annotations(page, sids)
        if scan?
          @report['image_only_pages'] += 1
          if @ocr
            @ocr_queue << [idx + 1, attrs, sids, @page]
          elsif @ocr_asked
            raise Error, "OCR is not available to read page #{idx + 1}"
          else
            @report['image_only_pages_not_read'] += 1
          end
        end
        @rasterize << (idx + 1) if @page[:rasterize]
        @labelled << [ref, page, res || {}] if @page[:labelled]
        @pages << surveyed(@page)
      end
      words = Ocr.read_pages(@input, @ocr_queue.map(&:first))
      @ocr_queue.zip(words).each do |(number, attrs, sids, page), w|
        @page = page
        ocr_page(number, attrs, sids, w)
        @rasterize << number if page[:rasterize]
      end
      @rasterize = @rasterize.uniq.sort
      if (unread = @report['image_only_pages_not_read']).positive?
        @report['notes'] << "#{unread} pages are only images: rules cannot " \
                            'match their text without OCR'
      end
      scan_objects
      add_label_fonts
      @report['notes'].uniq!
      @report
    end

    # The rewritten file, compressed by qpdf. qpdf warns when it has to
    # repair the edited file, and fix-qdf repairs it better.
    def write
      edits = @object_edits.dup
      @content_streams.uniq.each do |num|
        e = @edits[num] || { ops: {} }
        group = @groups[num]
        data = (group || [num]).map { |n| @doc.decoded(n).first }.join("\n")
        nd = legacy_pass(edited_stream(data, e[:ops]))
        next if nd == data && !e[:prefix] && !e[:suffix]

        data = "#{e[:prefix]}#{nd}#{e[:suffix]}".b
        edits.concat(@doc.stream_edits(num, data))
        group&.drop(1)&.each { |n| edits.concat(@doc.stream_edits(n, ''.b)) }
      end
      # Whatever qpdf writes, the file's content changed only if this did.
      @report['changed'] = edits.any?
      compress(@doc.rewrite(edits))
    end

    # The indexes of the rules that matched anywhere in the file.
    def rules_matched
      @rules.each_index.select { |i| @matched.include?(@rules[i]) }
    end

    # A PDF text string as text: UTF-16BE, UTF-16LE or UTF-8 by its byte
    # order mark, otherwise PDFDocEncoding. FinalScan reads strings this way.
    def self.decode_text_string(b)
      if b.start_with?("\xFE\xFF".b)
        b.byteslice(2..).force_encoding('UTF-16BE').
          encode('UTF-8', invalid: :replace, undef: :replace)
      elsif b.start_with?("\xFF\xFE".b)
        b.byteslice(2..).force_encoding('UTF-16LE').
          encode('UTF-8', invalid: :replace, undef: :replace)
      elsif b.start_with?("\xEF\xBB\xBF".b)
        b.byteslice(3..).force_encoding('UTF-8').scrub
      else
        b.bytes.map { |c| PDFDOC[c] || c.chr(Encoding::UTF_8) }.join
      end
    end

    def self.text?(data)
      !data.byteslice(0, 4096).include?("\x00") &&
        data.dup.force_encoding('UTF-8').valid_encoding?
    end

    private

    def edit(sid) = (@edits[sid] ||= { ops: {}, prefix: nil, suffix: nil })

    # The stream's data with each [start, stop) span replaced.
    def edited_stream(data, ops)
      out = String.new(encoding: Encoding::BINARY,
                       capacity: data.bytesize + 256)
      last = 0
      ops.keys.sort.each do |start|
        stop, rep = ops[start]
        out << data.byteslice(last, start - last) << rep
        last = stop
      end
      out << data.byteslice(last, data.bytesize - last)
    end

    def compress(edited)
      begin
        out, warnings = PDFRedactor.qpdf(edited, *COMPRESS)
        return out if warnings.strip.empty?
      rescue PDFRedactor.backend::ToolFailed => e
        warnings = e.message
      end
      @report['notes'] << "qpdf warned, fix-qdf used: " \
                          "#{warnings.lines.first&.strip}"
      PDFRedactor.qpdf(PDFRedactor.fix_qdf(edited), *COMPRESS).first
    end

    def surveyed(page)
      { 'number' => page[:number], 'visible' => page[:visible],
        'unmapped' => page[:unmapped],
        'picture_share' => (page[:image_area] / [page[:area], 1].max).round(4) }
    end

    def page_area(attrs)
      box = nums(attrs['CropBox'] || attrs['MediaBox'])
      return 612.0 * 792 unless box.size == 4

      ((box[2] - box[0]) * (box[3] - box[1])).abs
    end

    # A scan: little real text, pictures over most of the page with not much
    # text, or pictures of each line, as Word makes of a pasted scan.
    def scan?
      cover = @page[:image_area] / [@page[:area], 1].max
      v = @page[:visible]
      @page[:images].positive? &&
        (v < 5 || (cover >= 0.4 && v < 300) || (cover >= 0.1 && v < 100))
    end

    # The old masker's pass, on the bytes left after the decoded pass: each
    # match becomes "x" bytes. Plain-word rules no longer match here, as the
    # decoded pass rewrote their glyphs; rules pasted from a content stream do.
    def legacy_pass(data)
      @rules.each_with_index do |rule, i|
        next unless rule.legacy

        data = data.gsub(rule.legacy) do |m|
          @matched << rule
          @report['legacy_byte_matches'] += 1
          @report['legacy_rules_matched'] =
            @report.fetch('legacy_rules_matched', []) | [i]
          'x' * m.bytesize
        end
      end
      data
    end

    def font(res, name)
      fonts = @doc.resolve(res['Font'])
      ref = fonts.is_a?(Hash) ? fonts[name] : nil
      return nil unless (dict = @doc.resolve(ref)).is_a?(Hash)

      @fonts[ref.is_a?(Ref) ? ref.num : dict.object_id] ||= Font.new(@doc, dict)
    end

    def nums(v)
      PDFRedactor.list(@doc.resolve(v)).map { |x| num(@doc.resolve(x)) }
    end

    def num(v) = (v.is_a?(Numeric) ? v.to_f : 0.0)

    # Page area that an image drawn with this CTM covers.
    def area(ctm, outer) = determinant(mul(ctm, outer))

    def determinant(m) = ((m[0] * m[3]) - (m[1] * m[2])).abs

    def mul(m, n)
      [(m[0] * n[0]) + (m[1] * n[2]), (m[0] * n[1]) + (m[1] * n[3]),
       (m[2] * n[0]) + (m[3] * n[2]), (m[2] * n[1]) + (m[3] * n[3]),
       (m[4] * n[0]) + (m[5] * n[2]) + n[4],
       (m[4] * n[1]) + (m[5] * n[3]) + n[5]]
    end

    def unit_square_bbox(m)
      pts = [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]].map do |x, y|
        [(x * m[0]) + (y * m[2]) + m[4], (x * m[1]) + (y * m[3]) + m[5]]
      end
      xs = pts.map(&:first)
      ys = pts.map(&:last)
      [xs.min, ys.min, xs.max, ys.max]
    end

    def transform_points(points, m)
      return points if m == M1

      points.map do |x, y|
        [(x * m[0]) + (y * m[2]) + m[4], (x * m[1]) + (y * m[3]) + m[5]]
      end
    end

    def page_has_images?
      return false unless @page

      @page[:images].to_i.positive? || !@page[:image_boxes]&.empty?
    end

    def overlaps_page_image?(points)
      return false unless @page
      return true if @page[:image_boxes_overflow]
      return false unless @page[:image_boxes]&.any?

      xs = points.map(&:first)
      ys = points.map(&:last)
      bx0, bx1 = xs.minmax
      by0, by1 = ys.minmax
      @page[:image_boxes].any? do |ix0, iy0, ix1, iy1|
        ox = [bx1, ix1].min - [bx0, ix0].max
        oy = [by1, iy1].min - [by0, iy0].max
        ox.positive? && oy.positive? && (ox * oy) > 0.5
      end
    end

    def collect_page_images(sids, res, outer = M1, depth = 0, seen = Set.new)
      if depth > 8 || @page[:image_boxes].size >= 2000
        @page[:image_boxes_overflow] = true
        return
      end
      return if sids.empty?

      data = sids.filter_map { |sid| @doc.stream_data(sid) }.join("\n")
      return unless data.include?('Do') || data.include?('BI')

      xobjects = @doc.resolve(res['XObject'])
      xobjects = {} unless xobjects.is_a?(Hash)
      ctm = M1
      stack = []
      Lexer.each_op(data) do |op, a|
        if @page[:image_boxes].size >= 2000
          @page[:image_boxes_overflow] = true
          break
        end

        case op
        when 'q' then stack << ctm
        when 'Q' then ctm = stack.pop || ctm
        when 'cm'
          ctm = mul(a.map { |x| num(x) }, ctm) if a.size == 6
        when 'BI'
          @page[:image_boxes] << unit_square_bbox(mul(ctm, outer))
        when 'Do'
          ref = xobjects[a[0].to_s]
          xobject = @doc.resolve(ref)
          sub = xobject.is_a?(Hash) ? @doc.name(xobject['Subtype']) : nil
          if sub == 'Image'
            @page[:image_boxes] << unit_square_bbox(mul(ctm, outer))
          elsif sub == 'Form' && ref.is_a?(Ref)
            o = @doc.object(ref.num)
            next unless o && o[:stream] && o[:value].is_a?(Hash)

            own = @doc.resolve(o[:value]['Resources'])
            fres = own.is_a?(Hash) ? own : res
            fm = nums(o[:value]['Matrix'])
            fouter = mul(ctm, outer)
            fouter = mul(fm, fouter) if fm.size == 6
            next unless seen.add?([ref.num, fouter])

            collect_page_images([ref], fres, fouter, depth + 1, seen)
          end
        end
      end
    end

    # Areas that an author marked to redact but did not apply: everything
    # under them goes, as ISO 32000-1 12.5.6.23 asks, so the page is boxed and
    # becomes a picture of itself.
    def apply_redact_annotations(page, sids)
      refs = Array(@doc.resolve(page['Annots'])).select do |a|
        v = @doc.resolve(a)
        v.is_a?(Hash) && @doc.name(v['Subtype']) == 'Redact'
      end
      return if refs.empty?

      marks = refs.map { |a| @doc.resolve(a) }
      # A structure tree can still point to the annotation.
      refs.grep(Ref).each do |a|
        if @doc.object(a.num)[:stream]
          raise Error, "a /Redact annotation, object #{a.num}, is a stream"
        end

        @object_edits << [*@doc.object(a.num)[:dict], 'null'.b, :removal]
      end
      @report['redact_annotations'] += marks.size
      paths = marks.flat_map { |a| redact_rects(a) }.map do |x0, y0, x1, y1|
        rect = [x0, y0, x1 - x0, y1 - y0].map { |v| Serialize.dump(v) }
        "#{rect.join(' ')} re"
      end
      add_boxes(sids.map(&:num), paths) unless sids.empty? || paths.empty?
      @page[:rasterize] = true
    end

    def redact_rects(annot)
      q = nums(annot['QuadPoints'])
      r = nums(annot['Rect'])
      quads = q.size >= 8 ? q.each_slice(8).select { |c| c.size == 8 } : []
      if quads.empty? && r.size == 4
        quads = [r.values_at(0, 1, 2, 1, 2, 3, 0, 3)]
      end
      quads.map do |c|
        xs = c.values_at(0, 2, 4, 6)
        ys = c.values_at(1, 3, 5, 7)
        [xs.min, ys.min, xs.max, ys.max]
      end
    end

    def annot_streams(annot, res)
      unless annot.is_a?(Hash) && (ap = @doc.resolve(annot['AP'])).is_a?(Hash)
        return
      end

      %w[N R D].each do |k|
        v = ap[k]
        targets = if v.is_a?(Ref) && @doc.object(v.num)&.dig(:stream)
                    [v]
                  elsif (states = @doc.resolve(v)).is_a?(Hash)
                    states.values
                  else
                    []
                  end
        targets.each { |t| form(t, res, M1, on_contents: false) }
      end
    end

    # QdfDoc#unshare_contents gives each page its own streams, so a stream a
    # page also draws as a form can't be edited for both.
    def claim_page_streams(sids)
      sids.each do |sid|
        if @form_edits.key?(sid.num)
          raise Error, "object #{sid.num} is both page content and a form"
        end

        @page_streams << sid.num
      end
    end

    # outer: the form's matrix and the CTM where the page drew it, so the
    # pictures inside count towards the page's area. A form is read once for
    # each set of resources, and each page that draws it counts what's in it.
    def form(ref, res, outer = M1, on_contents: true)
      return unless ref.is_a?(Ref) && !@running.include?(ref.num)

      o = @doc.object(ref.num)
      return unless o && o[:stream] && o[:value].is_a?(Hash)

      own = @doc.resolve(o[:value]['Resources'])
      res = own if own.is_a?(Hash)
      m = nums(o[:value]['Matrix'])
      outer = mul(m, outer) if m.size == 6
      scale = determinant(outer)
      key = [ref.num, res.object_id]
      adds = (@forms[key] ||= read_form(ref, res))
      if @page
        @page[:images] += adds[:images]
        @page[:visible] += adds[:visible]
        @page[:unmapped] += adds[:unmapped]
        @page[:image_area] += adds[:image_area] * scale
      end
      if @form_box_collector
        if @form_box_collector.size + adds[:boxes].size > MAX_FORM_BOXES
          raise Error, 'too many redaction boxes in form'
        end

        adds[:boxes].each do |b|
          @form_box_collector << {
            corners: transform_points(b[:corners], outer),
            invisible: b[:invisible]
          }
        end
      else
        apply_form_boxes(adds[:boxes], outer, on_contents: on_contents)
      end
    end

    def apply_form_boxes(form_boxes, outer, on_contents:)
      return if !@page || form_boxes.empty?

      images = page_has_images?
      form_boxes.each do |b|
        page_corners = transform_points(b[:corners], outer)
        over_img = (b[:invisible] && images) ||
                   overlaps_page_image?(page_corners)
        if on_contents && (!b[:invisible] || over_img)
          @page[:extra_boxes] << path(page_corners)
          @report['boxes'] += 1 if b[:invisible]
        end
        next unless over_img

        @report['boxes_over_images'] += 1
        @page[:rasterize] = true
      end
    end

    # Reads the form and returns what it added in its own space. Its one stream
    # can't hold different edits for pages whose resources make it read
    # differently, so that fails.
    def read_form(ref, res)
      num = ref.num
      if @page_streams.include?(num)
        raise Error, "object #{num} is both page content and a form"
      end

      saved_page = @page
      saved_collector = @form_box_collector
      @page = { images: 0, visible: 0, unmapped: 0, image_area: 0.0,
                image_boxes: [], extra_boxes: [] }
      @form_box_collector = []
      earlier = @form_edits[num]
      @edits.delete(num)
      @running << num
      run_streams([ref], res, outer: M1, on_contents: false)
      @running.delete(num)
      edits = @edits[num] || { ops: {}, prefix: nil, suffix: nil }
      if earlier && earlier != edits
        raise Error, "form #{num} reads differently on different pages"
      end

      @form_edits[num] = edits
      { images: @page[:images],
        visible: @page[:visible],
        unmapped: @page[:unmapped],
        image_area: @page[:image_area],
        boxes: @form_box_collector }
    ensure
      @page = saved_page
      @form_box_collector = saved_collector
    end

    # Decodes the text of content streams that share one graphics state.
    def run_streams(sids, res, outer: M1, on_contents: true)
      glyphs = []
      ctxs = {}
      gs = { ctm: M1, tc: 0.0, tw: 0.0, th: 1.0, tl: 0.0, rise: 0.0,
             font: nil, tfs: 0.0, tr: 0 }
      stack = []
      underflow_qs = []
      tm = M1.dup
      tlm = M1
      forms = []
      done = []
      xobjects = @doc.resolve(res['XObject'])
      xobjects = {} unless xobjects.is_a?(Hash)
      # A page's streams are one stream cut at any token, even inside an
      # array, as Ghostscript 8 does. Read them joined; #write puts the
      # result in the first and empties the rest.
      units = sids.filter_map do |sid|
        (data = @doc.stream_data(sid)) && [sid.num, data]
      end
      if units.size > 1
        @groups[units.first[0]] = units.map(&:first)
        units = [[units.first[0], units.map(&:last).join("\n")]]
      end
      units.each do |num, data|
        done << num
        @content_streams << num
        oi = -1
        Lexer.each_op(data) do |op, a, start, stop|
          oi += 1
          case op
          when 'q' then stack << gs.dup
          when 'Q'
            if stack.empty?
              underflow_qs << [num, start, stop]
            else
              gs = stack.pop
            end
          when 'cm' then if a.size == 6
                           gs[:ctm] = mul(a.map { |x| num(x) }, gs[:ctm])
                         end
          when 'BT'
            tlm = M1
            tm = M1.dup
          when 'Tf'
            gs[:font] = font(res, a[0].to_s)
            gs[:tfs] = num(a[1])
            unless gs[:font]
              @report['notes'] << "font resource #{a[0]} not found"
            end
          when 'Tc' then gs[:tc] = num(a[0])
          when 'Tw' then gs[:tw] = num(a[0])
          when 'Tz' then gs[:th] = num(a[0]) / 100.0
          when 'TL' then gs[:tl] = num(a[0])
          when 'Ts' then gs[:rise] = num(a[0])
          when 'Tr' then gs[:tr] = a[0].to_i
          when 'Td', 'TD'
            gs[:tl] = -num(a[1]) if op == 'TD'
            tlm = mul([1.0, 0.0, 0.0, 1.0, num(a[0]), num(a[1])], tlm)
            tm = tlm.dup
          when 'Tm'
            tlm = a.map { |x| num(x) } if a.size == 6
            tm = tlm.dup
          when 'T*'
            tlm = mul([1.0, 0.0, 0.0, 1.0, 0.0, -gs[:tl]], tlm)
            tm = tlm.dup
          when 'Do'
            ref = xobjects[a[0].to_s]
            xobject = @doc.resolve(ref)
            sub = xobject.is_a?(Hash) ? @doc.name(xobject['Subtype']) : nil
            if sub == 'Image' && @page
              @page[:images] += 1
              @page[:image_area] += area(gs[:ctm], outer)
            end
            forms << [ref, mul(gs[:ctm], outer)] if sub == 'Form'
          when 'BI'
            if @page
              @page[:images] += 1
              @page[:image_area] += area(gs[:ctm], outer)
            end
          when 'BDC', 'DP'
            # /ActualText, /Alt and /E replace the glyphs in copy and search.
            if a[1].is_a?(Hash) && (props = censor_props(a[1]))
              @report['marked_content_censored'] += 1
              marked = "#{Serialize.dump(a[0])} #{Serialize.dump(props)} #{op}"
              edit(num)[:ops][start] = [stop, marked.b]
            end
          when 'Tj', 'TJ', "'", '"'
            if op != 'Tj' && op != 'TJ'
              if op == '"'
                gs[:tw] = num(a[0])
                gs[:tc] = num(a[1])
              end
              tlm = mul([1.0, 0.0, 0.0, 1.0, 0.0, -gs[:tl]], tlm)
              tm = tlm.dup
            end
            next unless (f = gs[:font])

            show(glyphs, ctxs, num, oi, op, a.dup, start, stop, f, gs, tm)
          end
        end
      end
      if done.any?
        @stream_balance[done.first] = { underflow_qs: underflow_qs,
                                        open_qs: stack.size }
      end
      # Forms are read first, as #boxes covers a match in hidden text only on
      # a page with pictures, and a form may draw them.
      if forms.size > MAX_FORM_PLACEMENTS
        raise Error, 'too many form placements'
      end

      forms.uniq.each do |r, m|
        form(r, res, m, on_contents: on_contents)
      end
      censor(glyphs, ctxs, done) unless glyphs.empty?
    end

    # Adds the glyphs of one text-showing operator and moves the text matrix.
    def show(glyphs, ctxs, sid, oi, op, a, start, stop, f, gs, tm)
      elems = if op == 'TJ'
                a[0].is_a?(Array) ? a[0] : []
              else
                [a.last]
              end
      ctx = ctxs[[sid, oi]] = { font: f, tfs: gs[:tfs], tc: gs[:tc],
                                tw: gs[:tw], codes: {}, op: op, args: a,
                                start: start, stop: stop }
      tfs = gs[:tfs]
      th = gs[:th]
      rise = gs[:rise]
      invisible = gs[:tr] == 3 || gs[:tr] == 7
      vertical = f.vertical
      ca, cb, cc, cd, ce, cf = gs[:ctm]
      ta, tb, tc, td, = tm
      big_a = (ta * ca) + (tb * cc)
      big_b = (ta * cb) + (tb * cd)
      big_c = (tc * ca) + (td * cc)
      big_d = (tc * cb) + (td * cd)
      len = Math.hypot(big_a, big_b)
      ux, uy = len.zero? ? [1.0, 0.0] : [big_a / len, big_b / len]
      size = (tfs * Math.hypot(big_c, big_d)).abs
      # Vertical writing (9.7.4.3) moves down the text space y axis.
      if vertical
        hv = Math.hypot(big_c, big_d)
        ux, uy = hv.zero? ? [0.0, -1.0] : [-big_c / hv, -big_d / hv]
        size = (tfs * len).abs
      end
      previous = nil # the last glyph of the string before, in a TJ array
      elems.each_with_index do |e, ei|
        if e.is_a?(Numeric)
          if vertical
            ty = -(e / 1000.0) * tfs
            tm[4] += ty * tc
            tm[5] += ty * td
          else
            tx = -(e / 1000.0) * tfs * th
            tm[4] += tx * ta
            tm[5] += tx * tb
          end
          next
        end
        next unless e.is_a?(PStr)

        ctx[:codes][ei] = f.codes(e.bytes)
        codes, lens = ctx[:codes][ei]
        x = (tm[4] * ca) + (tm[5] * cc) + ce + (big_c * rise)
        y = (tm[4] * cb) + (tm[5] * cd) + cf + (big_d * rise)
        # A font can give a glyph more advance than its shape takes, with a
        # number in the array that pulls the next string back into it. The
        # glyph then ends where that string starts, or its box would cover
        # the next glyph. A string pulled back to the glyph's start or past
        # it is drawn over it or somewhere else, and the glyph keeps its end.
        if previous && codes.any?
          ax = previous.x1 - previous.x0
          ay = previous.y1 - previous.y0
          along = (((x - previous.x0) * ax) + ((y - previous.y0) * ay)) /
                  ((ax * ax) + (ay * ay))
          if along.positive? && along < 1
            previous.x1 = x
            previous.y1 = y
          end
        end
        total = 0.0
        codes.each_with_index do |code, ci|
          clen = lens ? lens[ci] : f.code_size
          # Word spacing applies to the one-byte code 32 only (9.3.3).
          tw = clen == 1 && code == 32 ? gs[:tw] : 0.0
          if vertical
            tx = ((f.vertical_advance(code, clen) / 1000.0) * tfs) +
                 gs[:tc] + tw
            x1 = x + (tx * big_c)
            y1 = y + (tx * big_d)
          else
            tx = (((f.width(code, clen) / 1000.0) * tfs) + gs[:tc] + tw) * th
            x1 = x + (tx * big_a)
            y1 = y + (tx * big_b)
          end
          t = f.unicode(code, clen)
          glyphs << Glyph.new(sid, oi, ei, ci, t, x, y, x1, y1, ux, uy,
                              big_c * tfs, big_d * tfs, size, invisible, f)
          x = x1
          y = y1
          total += tx
          if t.include?("�")
            @report['glyphs_without_unicode'] += 1
            @page[:unmapped] += 1 if !invisible && @page
          elsif !invisible && @page && !t.match?(/\A\s*\z/)
            @page[:visible] += 1
          end
        end
        previous = glyphs.last if codes.any?
        @report['glyphs'] += codes.size
        @report['invisible_glyphs'] += codes.size if invisible
        if vertical
          tm[4] += total * tc
          tm[5] += total * td
        else
          tm[4] += total * ta
          tm[5] += total * tb
        end
      end
    end

    def same_line?(g, h)
      dx = h.x0 - g.x1
      dy = h.y0 - g.y1
      perp = ((dx * g.uy) - (dy * g.ux)).abs
      along = (dx * g.ux) + (dy * g.uy)
      fs = g.font_size > 1e-6 ? g.font_size : 1e-6
      perp <= 0.5 * fs && along >= -fs
    end

    def separator(g, h)
      return '' if g.text.match?(/\s\z/) || h.text.match?(/\A\s/)
      return LINE unless same_line?(g, h)

      along = ((h.x0 - g.x1) * g.ux) + ((h.y0 - g.y1) * g.uy)
      along > 0.2 * g.font_size ? GAP : ''
    end

    def text_of(glyphs, order)
      text = +''
      map = []
      prev = nil
      order.each_with_index do |gi, k|
        g = glyphs[gi]
        # A space that the next glyph overlaps takes no room on the page:
        # Chrome draws one where a soft hyphen did not break the word.
        n = order[k + 1]
        next if n && overlapped_space?(g, glyphs[n])

        if prev
          sep = separator(prev, g)
          unless sep.empty?
            text << sep
            map << nil
          end
        end
        t = NFKC[g.text]
        text << t
        t.length.times { map << gi }
        prev = g
      end
      [text, map]
    end

    # Reading order: lines from top to bottom, glyphs from left to right.
    def visual_order(glyphs)
      lines = []
      (0...glyphs.size).sort_by { |i| -glyphs[i].y0 }.each do |i|
        g = glyphs[i]
        line = lines.last
        if line && (line[:y] - g.y0).abs <= 0.5 * [g.font_size, line[:size]].max
          line[:items] << i
        else
          lines << { y: g.y0, size: g.font_size, items: [i] }
        end
      end
      lines.flat_map { |l| l[:items].sort_by { |i| glyphs[i].x0 } }
    end

    def overlapped_space?(g, h)
      h && g.text.match?(/\A\s+\z/) && same_line?(g, h) &&
        ((h.x0 - g.x0) * g.ux) + ((h.y0 - g.y0) * g.uy) < 0.1 * g.font_size
    end

    def match(glyphs, order, marked)
      text, map = text_of(glyphs, order)
      plain = nil
      @rules.each do |rule|
        subject = rule.literal ? text : (plain ||= text.tr(GAP + LINE, " \n"))
        subject.scan(rule.re) do
          m = Regexp.last_match
          hit = (m.begin(0)...m.end(0)).filter_map { |i| map[i] }
          next if hit.empty? || hit.all? { |gi| marked.include?(gi) }

          @report['matches'] += 1
          @matched << rule
          if hit.any? { |gi| glyphs[gi].invisible }
            @report['matches_in_invisible_text'] += 1
          end
          marked.merge(hit)
        end
      end
    end

    def censor(glyphs, ctxs, sids)
      marked = Set.new
      stream_order = (0...glyphs.size).to_a
      match(glyphs, stream_order, marked)
      visual = visual_order(glyphs)
      match(glyphs, visual, marked) unless visual == stream_order
      return if marked.empty?

      ops = marked.group_by { |gi| [glyphs[gi].sid, glyphs[gi].oi] }
      ops.each do |(sid, oi), gis|
        ctx = ctxs[[sid, oi]]
        @report['glyphs_censored'] += gis.size
        codes = gis.to_set { |gi| [glyphs[gi].ei, glyphs[gi].ci] }
        edit(sid)[:ops][ctx[:start]] = [ctx[:stop], rewrite(ctx, codes)]
      end
      boxes(glyphs, visual, marked, sids)
    end

    # A closed path through the points.
    def path(points)
      points.each_with_index.map do |(x, y), i|
        "#{Serialize.dump(x)} #{Serialize.dump(y)} #{i.zero? ? 'm' : 'l'}"
      end.join(' ') + ' h'
    end

    # One box for each run of marked glyphs on a line, painted after the
    # stream's own content in the stream's own space.
    def boxes(glyphs, visual, marked, sids)
      on_page = @page && sids.all? { |sid| @page_streams.include?(sid) }
      images = page_has_images?
      runs = []
      visual.each do |gi|
        g = glyphs[gi]
        keep = marked.include?(gi) && (!on_page || !g.invisible || images)
        unless keep
          runs << nil unless runs.last.nil?
          next
        end
        if runs.last && same_line?(glyphs[runs.last.last], g) &&
           (on_page || glyphs[runs.last.last].invisible == g.invisible)
          runs.last << gi
        else
          runs << [gi]
        end
      end
      labels = []
      paths = []
      runs.compact.each do |run|
        rg = run.map { |gi| glyphs[gi] }
        asc = rg.map { |g| g.font.ascent }.max
        desc = rg.map { |g| g.font.descent }.min
        first = rg.first
        last = rg.last
        corners = [[first.x0, first.y0, desc], [last.x1, last.y1, desc],
                   [last.x1, last.y1, asc], [first.x0, first.y0, asc]]
        corners = corners.map do |x, y, k|
          [x + (first.vx * k), y + (first.vy * k)]
        end
        inv = rg.any?(&:invisible)
        if !on_page && @form_box_collector
          if @form_box_collector.size >= MAX_FORM_BOXES
            raise Error, 'too many redaction boxes in form'
          end

          @form_box_collector << { corners: corners, invisible: inv }
        end
        next if !on_page && inv

        if on_page && (inv || overlaps_page_image?(corners))
          # A scan under or over the text still holds the words in its pixels.
          @report['boxes_over_images'] += 1
          @page[:rasterize] = true
        end
        labels << label(*corners.first(2), corners.last) if on_page
        paths << path(corners)
      end
      return if paths.empty?

      @report['boxes'] += paths.size
      # A form can be drawn by several pages, each with its own resources, so
      # only a box on the page itself can name the page's font.
      labels = on_page ? labels.compact : []
      @page[:labelled] = true if labels.any?
      add_boxes(sids, paths, labels)
    end

    # White on the box, centred, as big as fits: what the box hides reads as
    # [redacted] in the page's text, and PDFText counts it as seen. Black on
    # black would count as hidden.
    def label(start, stop, top)
      along = [stop[0] - start[0], stop[1] - start[1]]
      up = [top[0] - start[0], top[1] - start[1]]
      width = Math.hypot(*along)
      height = Math.hypot(*up)
      return if width < 1 || height < 1

      size = [height * 0.7, width / LABEL_EMS].min
      ax, ay = along.map { |v| v / width }
      ux, uy = up.map { |v| v / height }
      right = (width - (size * LABEL_EMS)) / 2
      lift = (height - (size * 0.7)) / 2
      matrix = [ax, ay, ux, uy,
                start[0] + (ax * right) + (ux * lift),
                start[1] + (ay * right) + (uy * lift)]
      "BT /#{LABEL_FONT} #{Serialize.dump(size)} Tf " \
        "#{matrix.map { |v| Serialize.dump(v) }.join(' ')} Tm " \
        "(#{LABEL}) Tj ET"
    end

    # Names the labels' font on each page that has them, in the page's own copy
    # of its resources, which may be inherited or shared. The page dictionary
    # and the copy are written from the file as it was read, so if either has
    # something censored in it, writing them would undo that: it fails and the
    # file is withheld, as any other that can't be masked.
    def add_label_fonts
      @labelled.uniq { |ref, _, _| ref }.each do |ref, page, res|
        raise Error, 'a page to label is not an object' unless ref.is_a?(Ref)

        fonts = @doc.resolve(res['Font'])
        fonts = fonts.is_a?(Hash) ? fonts : {}
        if fonts.key?(LABEL_FONT)
          # Labelled by an earlier pass (a masking rule, say): the labels use
          # the font as it is.
          next if @doc.resolve(fonts[LABEL_FONT]) == label_font

          # Any other font of that name: the label would take it over, and
          # the text drawn with it.
          raise Error, "page object #{ref.num} already has a font named " \
                       "#{LABEL_FONT}"
        end

        span = @doc.object(ref.num)[:dict]
        raise Error, "page object #{ref.num} has two edits" if edited?(span)

        resources = res.merge('Font' => fonts.merge(LABEL_FONT => label_font))
        copied = []
        collect_strings(resources, copied)
        if copied.any? { |s| edited?(s.span) }
          raise Error, "page object #{ref.num} would copy censored text"
        end

        dict = page.merge('Resources' => resources)
        @object_edits << [*span, Serialize.dump(dict).b]
      end
    end

    def label_font
      { 'Type' => Name.new('Font'), 'Subtype' => Name.new('Type1'),
        'BaseFont' => Name.new('Helvetica') }
    end

    # Whether an edit to an object already changes these bytes.
    def edited?(span)
      @object_edits.any? { |s, e, _| s < span[1] && e > span[0] }
    end

    # The stream's own content is wrapped in q ... Q, with any extra Q's
    # blanked and unclosed q's closed, so boxes draw in the starting space.
    def add_boxes(sids, paths, labels = [])
      # A page's joined streams are written to the first.
      sids = [sids.first] if @groups.key?(sids.first)
      edit(sids.first)[:prefix] ||= "q\n"
      if (bal = @stream_balance[sids.first])
        bal[:underflow_qs].each do |num, start, stop|
          edit(num)[:ops][start] = [stop, (' ' * (stop - start)).b]
        end
        close_qs = "Q\n" * (bal[:open_qs] + 1)
      else
        close_qs = "Q\n"
      end
      e = edit(sids.last)
      e[:suffix] ||= "\n#{close_qs}"
      e[:suffix] += "q 0 g #{paths.join("\n")} f Q\n"
      e[:suffix] += "q 1 g #{labels.join("\n")} Q\n" if labels.any?
    end

    # OCR misreads letters, such as "Miiller" for "Müller". Literal rules
    # also match words a few edits away, with accents and case ignored.
    def fuzzy_ocr(words, hit)
      @rules.each do |rule|
        next unless rule.literal && rule.text

        letters = !rule.text.match?(/\d/)
        norm = words.map { |w| Ocr.fold(w.text, letters: letters) }
        want = Ocr.fold(rule.text.gsub(/\s+/, ''), letters: letters)
        next if want.size < 5

        n = rule.text.split.size
        if n == 1
          norm.each_with_index do |w, i|
            next if hit.include?(i) || w.size <= want.size
            next unless Ocr.near_substring?(w, want)

            @report['ocr_fuzzy_matches'] += 1
            @matched << rule
            hit << i
          end
        end
        words.each_index do |i|
          (1..(n + 1)).each do |k|
            next if i + k > words.size

            got = norm[i, k].join
            next if (got.size - want.size).abs > want.size / 5

            d = Ocr.distance(got, want)
            next unless d <= want.size / 5
            # Each edge word must help the match, or "Mr" joins a name.
            next if k > 1 &&
                    (Ocr.distance(norm[i + 1, k - 1].join, want) <= d ||
                     Ocr.distance(norm[i, k - 1].join, want) <= d)

            next if (i...(i + k)).all? { |j| hit.include?(j) }

            @report['ocr_fuzzy_matches'] += 1
            @matched << rule
            hit.merge(i...(i + k))
          end
        end
      end
    end

    # A page that is only a picture: read it with OCR, box the words that
    # match, and mark the page to rasterise so the pixels go too.
    def ocr_page(number, attrs, sids, words)
      return if sids.empty?

      @report['ocr_pages'] += 1
      raise Error, "OCR could not read page #{number}" unless words

      text = +''
      map = []
      words.each_with_index do |w, i|
        unless i.zero?
          text << (w.line == words[i - 1].line ? ' ' : LINE)
          map << nil
        end
        t = NFKC[w.text]
        text << t
        t.length.times { map << i }
      end
      hit = Set.new
      @rules.each do |rule|
        (rule.literal ? text : text.tr(LINE, "\n")).scan(rule.re) do
          m = Regexp.last_match
          words_hit = (m.begin(0)...m.end(0)).filter_map { |k| map[k] }
          next if words_hit.empty?

          @report['ocr_matches'] += 1
          @matched << rule
          hit.merge(words_hit)
        end
      end
      fuzzy_ocr(words, hit)
      return if hit.empty?

      to_page = Ocr.to_page(attrs.transform_values { |v| @doc.resolve(v) },
                            @doc)
      paths = hit.map do |i|
        w = words[i]
        xs, ys = [[w.x0, w.y0], [w.x1, w.y1]].
                 map { |px, py| to_page.call(px, py) }.transpose
        x0, x1 = xs.minmax
        y0, y1 = ys.minmax
        [x0 - 1, y0 - 1, x1 - x0 + 2, y1 - y0 + 2].
          map { |v| Serialize.dump(v) }.join(' ') + ' re'
      end
      @report['ocr_boxes'] += paths.size
      add_boxes(sids.map(&:num), paths)
      @page[:rasterize] = true
    end

    def rewrite(ctx, set)
      f = ctx[:font]
      op = ctx[:op]
      tfs = ctx[:tfs]
      elems = op == 'TJ' ? ctx[:args][0] : [ctx[:args].last]
      out = []
      cur = +''.b
      flush = -> do
        next if cur.empty?

        out << PStr.new(cur, nil)
        cur = +''.b
      end
      push = ->(n) do
        flush.call
        out.last.is_a?(Numeric) ? out[-1] += n : out << n
      end
      elems.each_with_index do |e, ei|
        if e.is_a?(Numeric)
          push.call(e)
          next
        end
        next unless e.is_a?(PStr)

        codes, lens = ctx[:codes][ei]
        codes.each_with_index do |code, ci|
          len = lens ? lens[ci] : f.code_size
          unless set.include?([ei, ci])
            cur << f.code_bytes(code, len)
            next
          end
          wg = f.width(code, len)
          twg = len == 1 && code == 32 ? ctx[:tw] : 0.0
          push.call(-(wg + (tfs.zero? ? 0 : 1000.0 * (ctx[:tc] + twg) / tfs)))
        end
      end
      flush.call
      prefix = case op
               when "'" then 'T* '
               when '"'
                 aw, ac = ctx[:args].first(2).map { |v| Serialize.dump(v) }
                 "#{aw} Tw #{ac} Tc T* "
               else ''
               end
      "#{prefix}#{Serialize.dump(out)} TJ".b
    end

    def decode_text_string(b) = self.class.decode_text_string(b)

    def normalize_string(s)
      s.unicode_normalize(:nfkc).delete(UNSEEN_CHARS)
    rescue ArgumentError, Encoding::CompatibilityError
      s
    end

    # A match becomes [redacted], so that a name's word lengths don't show.
    def censor_string(s, normalized: false)
      out = s
      hit = false
      @rules.each do |rule|
        out = out.gsub(rule.re) do
          hit = true
          @matched << rule
          LABEL
        end
      end
      if !normalized && !out.ascii_only?
        norm = normalize_string(out)
        if norm != out && @rules.any? { |rule| norm.match?(rule.re) }
          rep = censor_string(norm, normalized: true)
          return rep if rep
        end
      end
      hit ? out : nil
    end

    # Same-length censoring of bytes that may hold Latin-1, UTF-8 or
    # UTF-16LE text, such as JPEG metadata.
    def censor_bytes(seg)
      out = seg.dup
      hit = false
      latin1 = seg.dup.force_encoding('ISO-8859-1').encode('UTF-8')
      views = [[latin1, ->(i) { i }]]
      utf8 = seg.dup.force_encoding('UTF-8')
      if utf8.valid_encoding? && !utf8.ascii_only?
        offs = [0]
        utf8.each_char { |c| offs << (offs.last + c.bytesize) }
        views << [utf8, ->(i) { offs[i] }]
      end
      u16 = seg.dup.force_encoding('UTF-16LE')
      if seg.bytesize.even? && u16.valid_encoding? &&
         seg.count("\x00") * 3 > seg.bytesize
        views << [u16.encode('UTF-8'), ->(i) { i * 2 }]
      end
      views.each do |text, at|
        @rules.each do |rule|
          text.scan(rule.re) do
            m = Regexp.last_match
            s = at.call(m.begin(0))
            e = at.call(m.end(0))
            out[s...e] = out.byteslice(s...e).gsub(/[^\x00]/n, 'x')
            hit = true
            @matched << rule
          rescue Encoding::UndefinedConversionError, ArgumentError
            next
          end
        end
      end
      hit ? out : nil
    end

    def censor_props(props)
      changed = false
      out = props.transform_values do |v|
        rep = v.is_a?(PStr) && censor_string(decode_text_string(v.bytes))
        next v unless rep

        changed = true
        PStr.new("\xFE\xFF".b + rep.encode('UTF-16BE').b, nil)
      end
      changed ? out : nil
    end

    def collect_strings(v, out)
      case v
      when PStr then out << v if v.span&.last
      when Array then v.each { |x| collect_strings(x, out) }
      when Hash
        return if @doc.name(v['Type']) == 'Sig'

        v.each_value { |x| collect_strings(x, out) }
      end
    end

    def filters(v)
      PDFRedactor.list(@doc.resolve(v['Filter'])).map { |f| @doc.name(f) }
    end

    # Text outside page content: PDF text strings (Info, bookmarks,
    # annotations, form fields), XMP, JPEG metadata and attached files.
    def scan_objects
      attached = @doc.attached_streams
      @doc.offsets.each_key do |n|
        o = @doc.object(n)
        next unless o

        strs = []
        collect_strings(o[:value], strs)
        strs.each do |s|
          next unless (rep = censor_string(decode_text_string(s.bytes)))

          @report['text_strings_censored'] += 1
          hex = rep.encode('UTF-16BE').unpack1('H*').upcase
          @object_edits << [s.span[0], s.span[1], "<FEFF#{hex}>".b]
        end
        v = o[:value]
        next unless o[:stream] && v.is_a?(Hash)

        # An attached file first, whatever else its dictionary says it is.
        if attached.include?(n)
          embedded(n, @doc.decoded(n).first)
        elsif @doc.name(v['Type']) == 'Metadata'
          xmp = @doc.decoded(n).first.dup.force_encoding('UTF-8').scrub
          if (rep = censor_string(xmp))
            @report['xmp_censored'] += 1
            @object_edits.concat(@doc.stream_edits(n, rep.b))
          end
        elsif @doc.name(v['Subtype']) == 'Image' &&
              filters(v).include?('DCTDecode')
          data, rest = @doc.decoded(n)
          if rest.first == 'DCTDecode' && (rep = censor_jpeg(data))
            @report['jpeg_metadata_censored'] += 1
            @object_edits.concat(@doc.stream_edits(n, rep))
          end
        end
      end
    end

    # JPEG APPn (Exif, XMP, IPTC) and COM segments. APP0 and APP14 stay: a
    # viewer needs them to decode the picture.
    def censor_jpeg(data)
      return nil unless data.start_with?("\xFF\xD8".b)

      out = data.dup
      hit = false
      p = 2
      while p + 1 < data.bytesize && data.getbyte(p) == 0xFF
        m = data.getbyte(p + 1)
        break if [0xDA, 0xD9].include?(m)

        # Stuffing, fill and restart markers carry no length.
        if m.zero? || m == 0xFF || m == 0x01 || (0xD0..0xD7).cover?(m)
          p += m == 0xFF ? 1 : 2
          next
        end
        break if p + 4 > data.bytesize

        len = data.byteslice(p + 2, 2).unpack1('n')
        break if len < 2

        if (m >= 0xE1 && m <= 0xEF && m != 0xEE) || m == 0xFE
          seg_len = [len - 2, data.bytesize - (p + 4)].min
          seg = data.byteslice(p + 4, seg_len)
          if (rep = censor_bytes(seg))
            out[p + 4, seg_len] = rep
            hit = true
          end
        end
        p += 2 + len
      end
      hit ? out : nil
    end

    def text?(data) = self.class.text?(data)

    # An attached PDF is masked on its own, and attached text is censored.
    # Any other attached file can't be checked, so it goes out as it came: a
    # PDF nested too deep, one with bytes before %PDF (which viewers open),
    # and anything that isn't a PDF or UTF-8 text, such as a Word file or text
    # in UTF-16.
    def embedded(num, data)
      if data.start_with?('%PDF')
        if @depth >= 3
          return leave("attached PDF (object #{num}) is nested more than " \
                       '3 deep')
        end
        return unless (masked = redact_attached(num, data))

        rep, sub = masked
        sub['rules_matched'].each { |i| @matched << @rules[i] }
        if (sub['matches'] + sub['text_strings_censored']).positive?
          @report['attached_pdfs_censored'] += 1
        end
        @report['attached_pdf_matches'] += sub['matches'].to_i
        @report['unmasked_parts'].concat(
          sub['unmasked_parts'].map { "in attached PDF (object #{num}): #{_1}" }
        )
        @object_edits.concat(@doc.stream_edits(num, rep, drop: ['Params']))
      elsif data.byteslice(0, 1024).include?('%PDF')
        leave("attached file (object #{num}) has bytes before %PDF")
      elsif text?(data)
        if (rep = censor_string(data.dup.force_encoding('UTF-8')))
          @report['attached_text_censored'] += 1
          @object_edits.concat(@doc.stream_edits(num, rep.b, drop: ['Params']))
        end
      else
        leave("attached file (object #{num}) is not a PDF or UTF-8 text")
      end
    end

    # The attached PDF masked, or nil if it needs a password: then it goes out
    # as it came, and the rest of the file is still masked.
    def redact_attached(num, data)
      PDFRedactor.redact(data, @rules, ocr: @ocr_asked, depth: @depth + 1)
    rescue PasswordRequired
      leave("attached PDF (object #{num}) needs a password")
      nil
    end

    # Masking is best effort: an attached file it can't reach goes out as it
    # came, and the report says which and why.
    def leave(why)
      @report['unmasked_parts'] << why
    end
  end
end
