module StatsHelper
  def stats_chart(kind, data, css_class: "stats-chart", label: nil, height: nil)
    tag.div(class: css_class, role: "img", aria: { label: label }.compact, style: height && "height: #{height}px",
            data: { controller: "release-chart",
                    release_chart_kind_value: kind,
                    release_chart_data_value: data.to_json })
  end

  # a ranked chart grows with its rows instead of squeezing them
  def stats_ranked_height(rows, legend: true)
    [ 360, rows * 22 + (legend ? 40 : 16) ].max
  end

  # mirrors the row layout in release_chart_controller.js: a folded row is
  # as many rows tall as its peak needs, up to four
  def stats_rows_height(series)
    max = [ 1, *series.reject { |s| s[:fold] }.flat_map { |s| s[:values] } ].max
    series.sum { |s| s[:fold] ? [ 4, [ 1, (s[:values].max.to_f / max).ceil ].max ].min : 1 } * 26 + 34
  end

  # someone who got the commit bit inside the cycle wears the month
  def stats_committer_badge(since)
    since ? "committer since #{since.strftime('%b %Y')}" : "committer"
  end

  def stats_pct(part, whole)
    return "0%" if whole.to_i.zero?

    "#{(part.to_f * 100 / whole).round}%"
  end

  def stats_number(value)
    number_with_delimiter(value.to_i)
  end

  def stats_share_segments(pairs)
    pairs.map { |label, value, definition, gray| { label: label, value: value, definition: definition, gray: gray }.compact }
  end

  def stats_initials(name)
    name.to_s.split.filter_map { |w| w[/\p{L}/] }.first(2).join.upcase
  end

  # sort link for a table column; the current column flips direction
  def stats_sort_header(path_helper, major, params_object, key, label)
    active = params_object.sort == key
    dir = active && params_object.dir == "desc" ? "asc" : "desc"
    arrow = active ? (params_object.dir == "desc" ? " \u25BE" : " \u25B4") : ""
    sort = { "desc" => "descending", "asc" => "ascending" }[params_object.dir] if active
    tag.th(class: [ "sortable", ("is-active" if active) ].compact.join(" "), aria: { sort: sort }.compact) do
      link_to "#{label}#{arrow}", send(path_helper, major, params_object.active_params.merge(sort: key, dir: dir))
    end
  end
end
