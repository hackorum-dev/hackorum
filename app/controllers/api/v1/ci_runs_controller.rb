module Api
  module V1
    class CiRunsController < BaseController
      query_params paged: true, on: :index

      def index
        branch_id = PatchBranch.where(lineage_only: false, id: path_param(:id)).pick(:id)
        raise ActiveRecord::RecordNotFound unless branch_id

        runs, next_cursor = paginate(PatchCiRun.where(patch_branch_id: branch_id).select(*PatchCiRun.list_columns),
                                     columns: %w[patch_ci_runs.created_at patch_ci_runs.id])
        render_page(CiRunSerializer.brief_list(runs, context), next_cursor)
      end
    end
  end
end
