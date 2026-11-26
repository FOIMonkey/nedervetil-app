# frozen_string_literal: true

module PDFRedactor
  # Pages of a PDF where a picture keeps pixels the page doesn't show: the
  # picture is clipped, runs off the page, or has a filled shape, a shading
  # or another picture drawn over part of it. The page looks clean, but the
  # whole picture is in the file and can be taken out of it, so a clean copy
  # that keeps such a page isn't clean (TextCopy).
  #
  # It follows each page's drawing operators, with the transformation,
  # saved states, clipping and form XObjects they use. Strokes don't count
  # (an outline round a picture hides almost nothing), and nor does text.
  # It's cautious: anything that overlaps a picture by more than a sliver
  # counts, including the boxes PDFRedactor draws over words on a picture.
  # It runs in the worker when the sandbox is required (Isolated).
  module PictureCover
    IDENTITY = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0].freeze
    # Square points of overlap below which edges only touch.
    SLIVER = 0.5
    MAX_DEPTH = 8
    FILLS = %w[f F f* B B* b b*].freeze
    STROKES = %w[S s].freeze

    module_function

    # The first such page's number, or nil.
    def first_page(pdf)
      return PDFRedactor.backend.picture_cover(pdf) if PDFRedactor.isolated?

      doc = document(pdf)
      doc.pages.each_with_index do |(page, resources, attrs, _ref), index|
        box = box_of(doc.resolve(attrs['CropBox'] || attrs['MediaBox']))
        state = { ctm: IDENTITY, clip: box, images: [], page: box }
        streams = contents(doc, page).filter_map { |ref| doc.stream_data(ref) }
        return index + 1 if covered?(doc, streams.join("\n"), resources,
                                     state, 0)
      end
      nil
    end

    def document(pdf)
      %w[none generalized].each do |level|
        qdf, = PDFRedactor.qpdf(pdf, '--qdf', '--object-streams=disable',
                                '--decrypt', '--normalize-content=n',
                                "--decode-level=#{level}")
        doc = PDFRedactor::QdfDoc.new(qdf)
        doc.pages.each do |page, *|
          contents(doc, page).each { |ref| doc.stream_data(ref) }
        end
        return doc
      rescue PDFRedactor::NeedsFullDecode
        raise if level == 'generalized'
      end
    end

    # The page's content stream references: /Contents is one, or an array
    # of them (itself perhaps behind a reference).
    def contents(doc, page)
      value = page['Contents']
      resolved = doc.resolve(value)
      resolved.is_a?(Array) ? resolved : [value]
    end

    # True as soon as a picture is found covered, clipped or off the page.
    def covered?(doc, data, resources, state, depth)
      return true if depth > MAX_DEPTH

      catch(:covered) do
        follow(doc, data, resources, state, depth)
        false
      end
    end

    def follow(doc, data, resources, state, depth)
      stack = []
      path = []
      clipping = false
      res = doc.resolve(resources)
      xobjs = res.is_a?(Hash) ? doc.resolve(res['XObject']) : nil
      xobjects = xobjs.is_a?(Hash) ? xobjs : {}
      PDFRedactor::Lexer.each_op(data) do |op, args|
        case op
        when 'q' then stack << state.slice(:ctm, :clip)
        when 'Q' then state.merge!(stack.pop) if stack.any?
        when 'cm'
          vals = numbers(args)
          state[:ctm] = multiply(vals.last(6), state[:ctm]) if vals.size >= 6
        when 'm', 'l', 'c', 'v', 'y'
          numbers(args).each_slice(2) do |x, y|
            path << apply(state[:ctm], x, y) if y
          end
        when 're'
          vals = numbers(args)
          if vals.size >= 4
            x, y, w, h = vals.last(4)
            [[x, y], [x + w, y], [x, y + h], [x + w, y + h]].
              each { |px, py| path << apply(state[:ctm], px, py) }
          end
        when 'W', 'W*' then clipping = true
        when *FILLS, *STROKES, 'n'
          area = bounds(path)
          if FILLS.include?(op) && area &&
             over_picture?(state, intersect(area, state[:clip]))
            throw :covered, true
          end
          state[:clip] = intersect(state[:clip], area) if clipping && area
          path = []
          clipping = false
        when 'sh'
          throw :covered, true if over_picture?(state, state[:clip])
        when 'BI'
          throw :covered, true if picture!(state)
        when 'Do'
          ref = xobjects[args.first.to_s]
          xobject = doc.resolve(ref)
          next unless xobject.is_a?(Hash)

          case doc.name(xobject['Subtype'])
          when 'Image'
            throw :covered, true if picture!(state)
          when 'Form'
            throw :covered, true if form_covered?(doc, ref, xobject,
                                                  resources, state, depth)
          end
        end
      end
    end

    # A form XObject: its own matrix, bounding box (as a clip) and
    # resources, with the pictures it draws added to the page's.
    def form_covered?(doc, ref, form, resources, state, depth)
      inner = state.merge(ctm: multiply(matrix(doc, form), state[:ctm]))
      if (box = box_of(doc.resolve(form['BBox'])))
        corners = [[box[0], box[1]], [box[2], box[1]],
                   [box[0], box[3]], [box[2], box[3]]]
        inner[:clip] = intersect(
          state[:clip], bounds(corners.map { |x, y| apply(inner[:ctm], x, y) })
        )
      end
      own = doc.resolve(form['Resources']) || resources
      covered = covered?(doc, doc.stream_data(ref) || '', own, inner, depth + 1)
      state[:images] = inner[:images]
      covered
    end

    # A picture drawn now: the unit square through the CTM. Covered if it's
    # clipped, off the page, or drawn over an earlier picture.
    def picture!(state)
      corners = [[0, 0], [1, 0], [0, 1], [1, 1]].
                map { |x, y| apply(state[:ctm], x, y) }
      area = bounds(corners)
      covered = !inside?(area, state[:clip]) || !inside?(area, state[:page]) ||
                over_picture?(state, area)
      state[:images] << area
      covered
    end

    def over_picture?(state, area)
      return false unless area

      state[:images].any? { |image| overlap(image, area) > SLIVER }
    end

    def matrix(doc, form)
      raw = PDFRedactor.list(doc.resolve(form['Matrix'])).
            map { |value| doc.resolve(value) }
      values = numbers(raw)
      values.size == 6 ? values : IDENTITY
    end

    def numbers(args)
      args.map { |value| value.respond_to?(:to_f) ? value.to_f : 0.0 }
    end

    # PDF's [a b c d e f]: m, then n.
    def multiply(m, n)
      a, b, c, d, e, f = m
      p, q, r, s, t, u = n
      [(a * p) + (b * r), (a * q) + (b * s), (c * p) + (d * r),
       (c * q) + (d * s), (e * p) + (f * r) + t, (e * q) + (f * s) + u]
    end

    def apply(m, x, y)
      [(m[0] * x) + (m[2] * y) + m[4], (m[1] * x) + (m[3] * y) + m[5]]
    end

    def bounds(points)
      return if points.empty?

      xs = points.map(&:first)
      ys = points.map(&:last)
      [xs.min, ys.min, xs.max, ys.max]
    end

    def box_of(values)
      raw = PDFRedactor.list(values)
      return unless raw.size == 4

      numbers(raw).then do |x0, y0, x1, y1|
        [[x0, x1].min, [y0, y1].min, [x0, x1].max, [y0, y1].max]
      end
    end

    def intersect(a, b)
      return a || b unless a && b

      box = [[a[0], b[0]].max, [a[1], b[1]].max,
             [a[2], b[2]].min, [a[3], b[3]].min]
      box[0] <= box[2] && box[1] <= box[3] ? box : [0, 0, 0, 0]
    end

    def overlap(a, b)
      box = intersect(a, b)
      (box[2] - box[0]) * (box[3] - box[1])
    end

    # Within, give or take a sliver at the edges.
    def inside?(area, box)
      return true unless box

      area[0] >= box[0] - 0.5 && area[1] >= box[1] - 0.5 &&
        area[2] <= box[2] + 0.5 && area[3] <= box[3] + 0.5
    end
  end
end
