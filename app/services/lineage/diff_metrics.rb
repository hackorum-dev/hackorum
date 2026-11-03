module Lineage
  # Numbers only. earlier/later naming matches the triangle; for a commit the
  # patchset is "earlier" and the commit "later".
  class DiffMetrics
    def self.compare(earlier, later) = new(earlier, later).compare

    def initialize(earlier, later)
      @a = earlier
      @b = later
    end

    def compare
      a_paths = @a.files.map(&:path).to_set
      b_paths = @b.files.map(&:path).to_set
      a_added, a_removed = lines(@a)
      b_added, b_removed = lines(@b)
      a_total = a_added.size + a_removed.size
      b_total = b_added.size + b_removed.size

      {
        "file_jaccard" => jaccard(a_paths, b_paths),
        "files_common" => (a_paths & b_paths).size,
        "files_only_earlier" => (a_paths - b_paths).size,
        "files_only_later" => (b_paths - a_paths).size,
        "added_jaccard" => jaccard(a_added, b_added),
        "removed_jaccard" => jaccard(a_removed, b_removed),
        "changed_jaccard" => jaccard(a_added | a_removed, b_added | b_removed),
        "lines_earlier" => a_total,
        "lines_later" => b_total,
        "size_ratio" => a_total.zero? ? nil : (b_total.fdiv(a_total)).round(3),
        "areas" => DiffParser::AREAS.to_h { |area| [ area.to_s, area_metrics(area) ] },
        "series" => series_metrics
      }
    end

    private

    def lines(parsed, area: nil)
      parsed.lines(area)
    end

    def area_metrics(area)
      a_added, a_removed = lines(@a, area: area)
      b_added, b_removed = lines(@b, area: area)
      {
        "added_jaccard" => jaccard(a_added, b_added),
        "removed_jaccard" => jaccard(a_removed, b_removed),
        "lines_earlier" => a_added.size + a_removed.size,
        "lines_later" => b_added.size + b_removed.size
      }
    end

    def series_metrics
      shared = @a.subjects & @b.subjects
      shift = shared.empty? ? nil : @b.subjects.index(shared.first) - @a.subjects.index(shared.first)
      {
        "patches_earlier" => @a.subjects.size,
        "patches_later" => @b.subjects.size,
        "shared_subjects" => shared.size,
        "subject_shift" => shift
      }
    end

    # nil when neither side has anything: "no data" is not "nothing in common"
    def jaccard(x, y)
      union = (x | y).size
      return nil if union.zero?
      ((x & y).size.fdiv(union)).round(4)
    end
  end
end
