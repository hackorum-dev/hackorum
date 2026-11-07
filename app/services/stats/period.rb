module Stats
  # One statistics subject: a window in time plus the rule that picks the
  # commits in it. The base is a plain time window (one middle phase, every
  # release tag an event, one row per change by cherry-pick key); Release
  # overrides the branch-based parts. Tabs read this interface only.
  class Period
    KINDS = %w[release year cycle].freeze
    # affiliation data is only curated from this cycle on
    COMPANIES_FROM_MAJOR = 19
    # LLM numbers are shown when this share of the commits with a thread has
    # a verdict; a partial run would skew every lineage and review tile
    LLM_MIN_COVERAGE = 0.8
    EVENT_TAG = /\AREL_(\d+)_(BETA\d+|RC\d+|0)\z/

    def self.kind_class(kind)
      KINDS.include?(kind.to_s) ? const_get(kind.to_s.camelize, false) : nil
    end

    def self.lookup(kind, key)
      kind_class(kind)&.find(key)
    end

    # by key inside the kind's list, so an unknown key is nil
    def self.find(key)
      available.find { |period| period.key == key.to_s }
    end

    # every period of every kind, newest first within a kind
    def self.all
      KINDS.flat_map { |kind| kind_class(kind).available }
    end

    # where the curated affiliation data begins: the PG19 cycle start
    def self.companies_from
      Release.new(COMPANIES_FROM_MAJOR).start
    end

    def kind = self.class.name.demodulize.downcase.to_sym

    def open? = !closed?

    def in_progress? = open?

    def in_progress_label = "in progress"

    # the h1 and page titles; label is the chip
    def title = label

    # inside a sentence: "landed in PG19", "landed in the 2025/26 cycle"
    def long_label = label

    # the comparison pills: "release 50%"
    def pill_noun = kind.to_s

    def scopes = @scopes ||= Scopes.new(self)

    def llm? = scopes.llm?

    def companies?
      return @companies unless @companies.nil?

      from = Period.companies_from
      @companies = from.present? && start >= from
    end

    # release only
    def branch_point = nil

    def previous_ga = nil

    def previous_landed_topics = nil

    # [[from, to, phase]]; one middle window means the message rule is
    # "everything on the lists" throughout
    def windows = [ [ start, end_at, :middle ] ]

    def phase_at(time)
      return windows.first.last if time < windows.first.first

      windows.find { |from, to, _| time >= from && time < to }&.last || windows.last.last
    end

    # every beta, rc and GA tag in the window, labelled with its major
    def events
      ReleaseTag.where(released_at: start..end_at)
                .where("name ~ ?", '^REL_\d+_(BETA\d+|RC\d+|0)$')
                .order(:released_at)
                .map do |tag|
        major, part = tag.name.match(EVENT_TAG).captures
        { at: tag.released_at, label: event_label(major.to_i, part) }
      end
    end

    # one row per logical change: the master copy when the group has one,
    # else its earliest member; the group counts when that commit's time is
    # inside the window. A back-branch-only fix counts, a cherry-pick of an
    # older master commit does not. Only groups with a member in the window
    # go through the DISTINCT ON
    def representatives_sql
      conn = Commit.connection
      from = conn.quote(start.utc.iso8601)
      to = conn.quote(end_at.utc.iso8601)
      <<~SQL.squish
        SELECT * FROM (
          SELECT DISTINCT ON (COALESCE(cherry_picked_from_sha, sha)) *
          FROM commits
          WHERE COALESCE(cherry_picked_from_sha, sha) IN (
            SELECT COALESCE(cherry_picked_from_sha, sha) FROM commits
            WHERE committed_at >= #{from} AND committed_at < #{to})
          ORDER BY COALESCE(cherry_picked_from_sha, sha), ('master' = ANY(branches)) DESC, committed_at, sha
        ) AS reps
        WHERE committed_at >= #{from} AND committed_at < #{to}
      SQL
    end

    # groups with a cherry-pick anywhere
    def backported_keys
      @backported_keys ||= Commit.where.not(cherry_picked_from_sha: nil)
                                 .where("cherry_picked_from_sha IN (SELECT COALESCE(cherry_picked_from_sha, sha) FROM (#{representatives_sql}) AS scope)")
                                 .distinct.pluck(:cherry_picked_from_sha)
    end

    def scope_description
      "committed between #{I18n.l(start.to_date)} and #{closed? ? I18n.l(last_date) : 'today'}, one per change, backports collapsed"
    end

    def backported_description = "cherry-picked to another branch too"

    # previous and next of the same kind, newest first, like the list
    def neighbours(list = self.class.available)
      index = list.index { |period| period.key == key } or return []
      [ (list[index - 1] if index.positive?), list[index + 1] ].compact
    end

    private

    def now = @now ||= Time.current

    def last_date = (end_at - 1.second).to_date

    def event_label(major, part)
      case part
      when "0" then "#{major}.0 GA"
      when "BETA1" then "#{major} branched (beta1)"
      else "#{major} #{part.downcase}"
      end
    end
  end
end
