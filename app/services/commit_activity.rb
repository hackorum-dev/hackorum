# frozen_string_literal: true

# Commit credits for a set of people over one year, loaded once and sliced in
# memory for the calendar, the counter boxes and the detail table.
#
# Only canonical commits are rows: cherry_picked_from_sha IS NULL. A backport
# contributes branch badges to the commit it was picked from and nothing else,
# so a change that landed on master and was backported three times is one row,
# dated by when it landed on master.
class CommitActivity
  # tested_by is left out: no longer in active use, and the profile header
  # band omits it too.
  ROLES = %w[author committer reviewer reported_by co_author].freeze

  # body is the full commit message and nothing here reads it
  ROW_COLUMNS = %i[id sha subject committed_at committer_name branches released_in cherry_picked_from_sha].freeze

  DEFAULT_SOURCES = %w[parsed].freeze

  # credits: person_id => { role => Set of sources }
  Entry = Struct.new(:commit, :credits, :committed_on, keyword_init: true) do
    def roles
      ROLES.select { |role| credits.each_value.any? { |by_role| by_role.key?(role) } }
    end

    def llm_roles = roles.select { |role| source_role?(role, "llm") }

    def committer_roles = roles.select { |role| source_role?(role, CommitterReviewer::SOURCE) }

    def llm_role?(role, person_id = nil) = source_role?(role, "llm", person_id)

    def source_role?(role, source, person_id = nil)
      sets = (person_id ? [ credits[person_id] ] : credits.values).filter_map { |by_role| by_role&.dig(role) }
      sets.any? && sets.all? { |sources| sources == Set[source] }
    end
  end

  def self.available_years(person_ids, sources: DEFAULT_SOURCES)
    ids = Array(person_ids)
    return [] if ids.empty?

    CommitPerson.shown.where(source: sources).joins(:commit).merge(Commit.canonical)
                .where(person_id: ids, role: ROLES)
                .distinct
                .pluck(Arel.sql("EXTRACT(YEAR FROM commits.committed_at)"))
                .map(&:to_i)
                .sort
                .reverse
  end

  def initialize(person_ids:, year:, roles: ROLES, sources: DEFAULT_SOURCES, wday_start: WeekCalculation::DEFAULT_WEEK_START)
    @person_ids = Array(person_ids)
    @year = year.to_i
    @roles = Array(roles).select { |role| ROLES.include?(role) }
    @sources = Array(sources)
    @wday_start = wday_start
  end

  def daily_counts
    @daily_counts ||= entries.map(&:committed_on).tally
  end

  def detail_rows_in(range)
    detail_rows.select { |row| range.cover?(row[:committed_on]) }
  end

  def summary_in(range)
    rows = detail_rows_in(range)
    role_counts = ROLES.to_h { |role| [ role.to_sym, rows.count { |row| row[:roles].include?(role) } ] }
    { total: rows.size, backported: rows.count { |row| row[:backported] },
      committer_reviewers: rows.count { |row| row[:member_credits].any? { |c| c[:committer_roles].include?("reviewer") } } }.merge(role_counts)
  end

  private

  # The calendar grid spans whole weeks, so it reaches into the neighbouring
  # years. Loading the grid rather than Jan 1 - Dec 31 keeps those edge squares
  # accurate; every day/week/month period inside the year is covered too.
  def loaded_range
    @loaded_range ||= begin
      start_date, end_date = WeekCalculation.year_weeks_range(@year, @wday_start)
      start_date.beginning_of_day..end_date.end_of_day
    end
  end

  def entries
    @entries ||= load_entries
  end

  # Built for the whole loaded window in one go, so slicing a month or a day
  # out of it costs no further query.
  def detail_rows
    @detail_rows ||= build_detail_rows(entries)
  end

  def load_entries
    return [] if @person_ids.empty? || @roles.empty?

    credits = CommitPerson.shown.where(source: @sources).joins(:commit).merge(Commit.canonical)
                          .where(person_id: @person_ids, role: @roles)
                          .where(commits: { committed_at: loaded_range })
                          .pluck("commit_people.commit_id", "commit_people.role", "commit_people.person_id", "commit_people.source")
    return [] if credits.empty?

    commits = Commit.where(id: credits.map(&:first).uniq).select(ROW_COLUMNS).index_by(&:id)

    grouped = {}
    credits.each do |commit_id, role, person_id, source|
      commit = commits[commit_id]
      next unless commit

      entry = grouped[commit_id] ||= Entry.new(commit: commit, credits: {}, committed_on: commit.committed_at.to_date)
      ((entry.credits[person_id] ||= {})[role] ||= Set.new) << source
    end

    # newest first; the sha only breaks ties so same-second commits keep a
    # stable order rather than jittering between requests
    grouped.values.sort_by { |entry| [ entry.commit.committed_at, entry.commit.sha ] }.reverse
  end

  def build_detail_rows(entries)
    return [] if entries.empty?

    backports = Commit.where(cherry_picked_from_sha: entries.map { |entry| entry.commit.sha })
                      .select(ROW_COLUMNS)
                      .group_by(&:cherry_picked_from_sha)
    commit_topics = CommitTopic.trailer.where(commit_id: entries.map { |entry| entry.commit.id })
                              .includes(:topic)
                              .group_by(&:commit_id)
    people = Person.includes(:default_alias)
                   .where(id: entries.flat_map { |entry| entry.credits.keys }.uniq)
                   .index_by(&:id)

    entries.map do |entry|
      commit = entry.commit
      picked = backports[commit.sha] || []

      {
        commit: commit,
        committed_on: entry.committed_on,
        roles: entry.roles,
        llm_roles: entry.llm_roles,
        committer_roles: entry.committer_roles,
        member_credits: member_credits_for(entry, people),
        branches: Commit.branch_badges([ commit ] + picked),
        backported: picked.any?,
        topics: (commit_topics[commit.id] || []).map(&:topic)
      }
    end
  end

  # Same race as the missing commit above: the person row can vanish between
  # the credits pluck and the lookup, and dropping one credit beats a 500.
  def member_credits_for(entry, people)
    entry.credits.filter_map do |person_id, by_role|
      person = people[person_id]
      next unless person

      roles = ROLES.select { |role| by_role.key?(role) }
      { person: person, roles: roles, llm_roles: roles.select { |role| entry.llm_role?(role, person_id) },
        committer_roles: roles.select { |role| entry.source_role?(role, CommitterReviewer::SOURCE, person_id) } }
    end
  end
end
