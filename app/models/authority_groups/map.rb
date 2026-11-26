module AuthorityGroups
  # ONS district boundaries (data/authority_groups/geography.json) matched via
  # `gss:<code>` tags. Abolished council areas (`ended`) render on their own
  # page but never as neighbours.
  module Map
    # District-level GSS prefixes only (excludes e.g. E10 counties) so mistyped
    # district codes are still validated and flagged as unknown.
    DISTRICT_CODE = /\A(E0[6-9]|W06|S12|N09)/
    # Minimum viewBox size in map units (~650 m each) for small districts.
    MIN_FRAME = 120

    module_function

    def data
      @data ||= if (file = ThemeData.file('authority_groups/geography.json'))
                  JSON.parse(File.read(file)).freeze
                else
                  { 'areas' => [] }.freeze
                end
    end

    def areas_by_code
      @areas_by_code ||= data['areas'].index_by { |area| area['code'] }.freeze
    end

    def current_areas
      @current_areas ||= data['areas'].reject { |area| area['ended'] }.freeze
    end

    def current?(code)
      @current_codes ||= current_areas.to_set { |area| area['code'] }.freeze
      @current_codes.include?(code)
    end

    def partly_current?(codes)
      codes.any? { |code| current?(code) } &&
        !codes.all? { |code| current?(code) }
    end

    # Ordered by model_id so a shared gss: code deterministically picks lowest.
    def tags_for(ids)
      HasTagString::HasTagStringTag.
        where(model_type: 'PublicBody', name: 'gss', model_id: ids).
        where.not(value: [nil, '']).order(:model_id, :id).
        pluck(:model_id, :value)
    end

    # Prefer current codes when present so leftover pre-boundary codes don't
    # draw a second area.
    def codes_for(bodies)
      chosen =
        tags_for(bodies.select(:id)).group_by(&:first).flat_map do |id, pairs|
          codes = pairs.map(&:last).select { |code| areas_by_code.key?(code) }
          current = codes.select { |code| current?(code) }
          (current.presence || codes).map { |code| [code, id] }
        end
      found = PublicBody.where(id: chosen.map(&:last)).
              includes(:translations).index_by(&:id)
      chosen.each_with_object({}) do |(code, id), by_code|
        by_code[code] ||= found[id]
      end.compact
    end

    def for_group(bodies)
      by_code = codes_for(bodies)
      members = current_areas.select { |area| by_code.key?(area['code']) }
      frame(members, by_code)
    end

    def for_body(body)
      by_code = codes_for(PublicBody.where(id: body.id))
      own = by_code.keys.filter_map { |code| areas_by_code[code] }
      frame(own, by_code)
    end

    # Members drawn last, so their outline sits on top.
    def frame(members, by_code)
      return nil if members.empty?

      x0, y0, x1, y1 = members.map { |area| area['box'] }.transpose.
                       then { |a, b, c, d| [a.min, b.min, c.max, d.max] }
      size = [([x1 - x0, y1 - y0].max * 1.3) + 16, MIN_FRAME].max
      cx = (x0 + x1) / 2.0
      cy = (y0 + y1) / 2.0
      box = [cx - (size / 2), cy - (size / 2), cx + (size / 2), cy + (size / 2)]
      member_codes = members.to_set { |area| area['code'] }
      neighbours =
        current_areas.reject { |area| member_codes.include?(area['code']) }.
        select do |area|
          ax0, ay0, ax1, ay1 = area['box']
          ax0 < box[2] && ax1 > box[0] && ay0 < box[3] && ay1 > box[1]
        end
      {
        view_box: [box[0], box[1], box[2] - box[0], box[3] - box[1]].
          map { |v| v.round(1) }.join(' '),
        areas: (neighbours + members).map do |area|
          {
            d: area['d'],
            body:
              member_codes.include?(area['code']) ? by_code[area['code']] : nil
          }
        end
      }
    end

    Check = Struct.new(:not_on_map, :old_codes, :shared, keyword_init: true) do
      def any?
        not_on_map.any? || old_codes.any? || shared.any?
      end
    end

    def check
      rows = district_rows
      bodies = PublicBody.where(id: rows.map(&:first).uniq).
               includes(:translations).index_by(&:id)
      by_body = codes_by_body(rows, bodies)
      Check.new(not_on_map: not_on_map(by_body),
                old_codes: old_codes(by_body),
                shared: shared_codes(rows, bodies))
    end

    def district_rows
      defunct = HasTagString::HasTagStringTag.
                where(model_type: 'PublicBody', name: 'defunct').
                select(:model_id)
      tags_for(PublicBody.where.not(id: defunct).select(:id)).
        select { |_, code| code.match?(DISTRICT_CODE) }
    end

    def codes_by_body(rows, bodies)
      grouped = rows.group_by(&:first).filter_map do |id, pairs|
        bodies[id] && [bodies[id], pairs.map(&:last)]
      end
      grouped.sort_by { |body, _| body.name }
    end

    def not_on_map(by_body)
      by_body.reject { |_, codes| codes.any? { |code| current?(code) } }
    end

    def old_codes(by_body)
      by_body.select { |_, codes| partly_current?(codes) }.
        map { |body, codes| [body, codes.reject { |code| current?(code) }] }
    end

    def shared_codes(rows, bodies)
      shared =
        rows.select { |_, code| current?(code) }.group_by(&:last).
        filter_map do |code, pairs|
          [code, pairs.filter_map { |id, _| bodies[id] }] if pairs.size > 1
        end
      shared.sort
    end

    def describe(code)
      area = areas_by_code[code]
      if area
        "#{code} (#{area['name']}#{', ended' if area['ended']})"
      else
        "#{code} (unknown code)"
      end
    end
  end
end
