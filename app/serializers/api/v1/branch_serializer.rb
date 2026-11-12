module Api
  module V1
    # A PatchBranch loaded through PatchCi::BranchRows from a relation that went
    # through BranchHealth#with_reason. `repo_state` in the
    # extras is the one the rows were loaded with, nil when there is none.
    class BranchSerializer < BaseSerializer
      TEXT_LIMIT = 2000
      REF_COLUMNS = %i[id branch_name status ci_status pushed_at].freeze

      # needs REF_COLUMNS only
      def ref
        { **REF_COLUMNS.index_with { |name| record.public_send(name) }, url: api_url("/branches/#{record.id}") }
      end

      def brief
        {
          id: record.id,
          url: api_url("/branches/#{record.id}"),
          html_url: site_url(routes.ci_topic_path(record.topic_id)),
          branch_name: record.branch_name,
          topic: topic_ref(record.topic),
          message_id: record.message_id,
          status: record.status,
          failure_stage: record.failure_stage,
          failure_reason: record.failure_reason&.first(TEXT_LIMIT),
          conflict_files: record.conflict_files,
          state: record.health_bucket,
          state_reason: state_reason,
          superseded: record.superseded_by_id.present?,
          base_sha: record.base_sha,
          base_source: record.base_source,
          base_committed_at: record.base_committed_at,
          on_master: record.on_master,
          pg_major: record.pg_major,
          behind: behind,
          attempted_at: record.attempted_at,
          pushed_at: record.pushed_at,
          pushed_head_sha: record.pushed_head_sha,
          github_url: record.pushed_at && helpers.ci_github_branch_url(record.branch_name),
          git_url: record.pushed_at && helpers.ci_github_clone_url,
          last_master_apply_at: record.last_master_apply_at,
          master_apply_sha: record.master_apply_sha,
          master_apply_error: record.master_apply_error&.first(TEXT_LIMIT),
          master_conflict_files: record.master_conflict_files,
          ci_status: record.ci_status,
          ci_skip_reason: record.ci_skip_reason,
          latest_run: latest_run,
          created_at: record.created_at,
          updated_at: record.updated_at
        }
      end

      private

      # the reason column is filled for every row, whatever its state
      def state_reason
        record.wont_retry_reason if record.health_bucket == "wont_retry"
      end

      # a repo state fetched during a push can trail the base
      def behind
        days = record.behind_days(extras[:repo_state])
        commits = record.behind_commits(extras[:repo_state])
        return if days.nil? && commits.nil?

        { days: days && [ days, 0 ].max, commits: commits && [ commits, 0 ].max }
      end

      def latest_run
        run = record.latest_run_summary
        run && CiRunSerializer.new(run, context).brief
      end
    end
  end
end
