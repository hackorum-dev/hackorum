class Commit < ApplicationRecord
  MASTER = "master".freeze
  STABLE_BRANCH_RE = /\AREL_?(\d+)(?:_(\d+))?_STABLE\z/

  has_many :commit_files, dependent: :delete_all
  has_many :commit_people, dependent: :delete_all
  has_many :commit_topics, dependent: :delete_all
  has_many :topics, through: :commit_topics

  validates :sha, presence: true, uniqueness: true

  scope :for_topic, ->(topic_id, sources: %w[trailer]) {
    joins(:commit_topics).where(commit_topics: { topic_id: topic_id, source: sources }).order(committed_at: :desc)
  }

  # The commit that actually landed the change, as opposed to a cherry-pick
  # of it into a stable branch.
  scope :on_master, -> { where("commits.branches @> ARRAY[?]::varchar[]", MASTER) }

  # A cherry-pick of another (usually master) commit into a stable branch.
  scope :backports, -> { where.not(cherry_picked_from_sha: nil) }

  # The change as it originally landed, as opposed to a cherry-pick of it.
  scope :canonical, -> { where(cherry_picked_from_sha: nil) }

  def released?
    released_in.present?
  end

  def display_version(branch)
    return "devel" if branch == MASTER

    major, minor = self.class.stable_branch_parts(branch)
    return branch.to_s unless major

    minor ? "#{major}.#{minor}" : major.to_s
  end

  def sorted_branches
    branches.sort_by { |b| self.class.branch_sort_key(b) }
  end

  # Collapses backports into one entry per logical change. Returns
  # [{ sha:, subject:, committed_at:, committer_name:, commit_ids:,
  #    branches: [{ branch:, version:, released_in:, released_label: }] }]
  def self.group_backports(commits)
    grouped = commits.group_by { |c| c.cherry_picked_from_sha.presence || c.sha }

    grouped.map do |canonical_sha, members|
      canonical = members.find { |c| c.sha == canonical_sha } ||
                  best_representative(members)
      {
        sha: canonical.sha,
        subject: canonical.subject,
        committed_at: canonical.committed_at,
        committer_name: canonical.committer_name,
        commit_ids: members.map(&:id),
        branches: branch_badges(members)
      }
    end.sort_by { |group| group[:committed_at] }.reverse
  end

  # Branch badge rows for one logical change: [{ branch:, version:,
  # released_in:, released_label: }], newest branch first, one row per branch.
  #
  # One branch can turn up on several members - a group can hold more than one
  # commit touching the same branch - and repeating the badge says nothing, so
  # the earliest release carrying that branch wins. The sort key includes the
  # label to keep the survivor deterministic, since sort_by is not stable.
  def self.branch_badges(members)
    members.flat_map { |member|
      member.sorted_branches.map do |branch|
        {
          branch: branch,
          version: member.display_version(branch),
          released_in: member.released_in,
          released_label: member.released_in.presence || "unreleased"
        }
      end
    }.sort_by { |row| [ branch_sort_key(row[:branch]), row[:released_label] ] }
     .uniq { |row| row[:branch] }
  end

  def self.branch_sort_key(branch)
    return [ 0, 0, 0 ] if branch == MASTER

    major, minor = stable_branch_parts(branch)
    return [ 2, 0, 0 ] unless major

    [ 1, -major, -(minor || 0) ]
  end

  # When a backport's cherry_picked_from_sha target is not in the collection
  # (normal for topic-scoped lists), represent the group by its
  # highest-priority branch: master, then newest stable branch.
  def self.best_representative(members)
    members.min_by do |c|
      [ c.branches.map { |b| branch_sort_key(b) }.min || [ 3, 0, 0 ], c.committed_at, c.sha ]
    end
  end
  private_class_method :best_representative

  # Parses a REL_18_STABLE / REL9_5_STABLE branch name into [major, minor]
  # (minor nil for modern one-part branches), or nil when it does not match.
  def self.stable_branch_parts(branch)
    m = branch.to_s.match(STABLE_BRANCH_RE)
    return nil unless m

    [ m[1].to_i, m[2]&.to_i ]
  end
end
