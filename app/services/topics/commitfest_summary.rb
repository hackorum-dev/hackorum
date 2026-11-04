module Topics
  class CommitfestSummary
    OPEN_STATUSES = [ "Needs review", "Waiting on Author", "Ready for Committer" ].freeze
    CLOSED_STATUSES = [ "Committed", "Rejected", "Returned with feedback", "Withdrawn" ].freeze
    MOVED = "Moved to different CF".freeze

    Patch = Struct.new(:external_id, :title, :status, :commitfest_name, :commitfest_external_id,
                       :reviewers, :committer, :tags, :ci_status, :history, keyword_init: true) do
      def open? = OPEN_STATUSES.include?(status)
      def closed? = CLOSED_STATUSES.include?(status)
    end

    def initialize(topic)
      @topic = topic
    end

    def patches
      @patches ||= rows.group_by { |row| row.commitfest_patch.external_id }.map do |_, patch_rows|
        latest = patch_rows.first
        cp = latest.commitfest_patch
        Patch.new(
          external_id: cp.external_id,
          title: cp.title,
          status: latest.status,
          commitfest_name: latest.commitfest.name,
          commitfest_external_id: latest.commitfest.external_id,
          reviewers: Topic.parse_csv_list(cp.reviewers),
          committer: cp.committer.to_s.strip.presence,
          tags: cp.commitfest_tags.map(&:name),
          ci_status: latest.ci_status,
          history: patch_rows.reverse.map { |row|
            { name: row.commitfest.name, external_id: row.commitfest.external_id, status: row.status }
          }
        )
      end
    end

    def any? = patches.any?
    def open_patches = patches.select(&:open?)
    def all_closed? = patches.all?(&:closed?)
    def final_statuses = patches.map(&:status).uniq
    def latest_commitfest_name = patches.first&.commitfest_name

    def moved_count
      patches.sum { |patch| patch.history.count { |entry| entry[:status] == MOVED } }
    end

    private

    def rows
      CommitfestPatchCommitfest
        .joins(:commitfest, commitfest_patch: :commitfest_patch_topics)
        .includes(:commitfest, commitfest_patch: :commitfest_tags)
        .where(commitfest_patch_topics: { topic_id: @topic.id })
        .order("commitfests.end_date DESC, commitfests.start_date DESC")
        .to_a
    end
  end
end
