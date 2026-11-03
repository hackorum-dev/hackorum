module Lineage
  class BranchApplier
    def initialize(repo_path:, worktrees_dir:, worktree_name: "lineage0")
      @repo = PatchBranches::GitRepo.new(repo_path)
      @worktree_path = File.join(worktrees_dir, worktree_name)
    end

    def call(patchsets)
      master_sha = @repo.rev_parse("master")
      raise "no master ref in #{@repo.dir}" unless master_sha
      worktree = nil

      patchsets.to_h do |ps|
        row = PatchBranch.find_by(message_id: ps.message.id)
        next [ ps.message.id, { status: "not_attempted", reason: "nocfbot" } ] if row.nil? && ps.nocfbot
        if row.nil? && ps.parse_error.nil?
          worktree ||= prepare_worktree
          apply_one = PatchBranches::ApplyOne.new(repo: @repo, worktree: worktree, lineage_only: true)
          begin
            outcome, row = apply_one.call(ps.message.id, master_sha: master_sha)
            next [ ps.message.id, { status: "infra_failed" } ] if outcome == :infra_failed && !row&.persisted?
          rescue => e
            save_error = apply_one.persist_error(e)
            Rails.logger.error("lineage apply #{ps.message.id}: #{save_error.class}: #{save_error.message}") if save_error
            row = apply_one.record
            unless row&.persisted?
              next [ ps.message.id, { status: "error", error: "#{e.class}: #{e.message}" } ]
            end
          end
        end
        [ ps.message.id, self.class.summarize(row) ]
      end
    end

    def self.summarize(row)
      return { status: "not_attempted" } if row.nil? || !row.persisted?
      { status: row.status, base_sha: row.base_sha, on_master: row.on_master,
        base_source: row.base_source, failure_stage: row.failure_stage,
        branch_name: row.branch_name, lineage_only: row.lineage_only }
    end

    private

    def prepare_worktree
      @repo.ensure_worktree!(@worktree_path)
      PatchBranches::GitRepo.new(@worktree_path)
    end
  end
end
