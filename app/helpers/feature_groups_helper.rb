module FeatureGroupsHelper
  def feature_version_line(version)
    d = version.details || {}
    changes = d["changes"].to_i
    parts = [ "PostgreSQL #{version.major}", version.status, version.role, d["size"] ]
    if changes.positive?
      parts << pluralize(changes, "commit")
      parts << feature_lines_text(d["lines_added"], d["lines_removed"])
    end
    parts.compact_blank.join(" · ")
  end

  private

  def feature_lines_text(added, removed)
    return "lines unknown" if added.nil? && removed.nil?

    "+#{feature_count_text(added.to_i)} / -#{feature_count_text(removed.to_i)} lines"
  end

  def feature_count_text(n)
    return n.to_s if n < 1000

    "#{(n / 1000.0).round(1).to_s.delete_suffix('.0')}k"
  end
end
