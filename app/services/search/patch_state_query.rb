# frozen_string_literal: true

module Search
  class PatchStateQuery
    CI_STATUSES = {
      "passing" => %w[success],
      "failing" => %w[build_failed build_timeout tests_failed tests_timeout],
      "pending" => %w[pushed_awaiting_ci queued running],
      "none" => %w[ci_none push_failed cancelled infra_error]
    }.freeze

    def self.current_branches
      PatchBranch.current.where(<<~SQL.squish)
        NOT EXISTS (SELECT 1 FROM patch_branches newer
                    WHERE newer.topic_id = patch_branches.topic_id
                      AND newer.superseded_by_id IS NULL AND NOT newer.lineage_only
                      AND newer.id > patch_branches.id)
      SQL
    end

    def self.ci(value)
      statuses = CI_STATUSES.fetch(value)
      statuses += [ nil ] if value == "none"
      current_branches.where(ci_status: statuses).select(:topic_id)
    end

    def self.apply(bucket, repo_state: PatchCiRepoState.current)
      matching = PatchCi::BranchHealth.new(repo_state: repo_state).filter(current_branches, [ bucket ])
      PatchBranch.where(id: matching.select(:id)).select(:topic_id)
    end
  end
end
