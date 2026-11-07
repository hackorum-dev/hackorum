class LineageBundleJob < ApplicationJob
  queue_as :default

  def perform(run_id)
    run = PatchsetRun.find_by(id: run_id)
    Lineage::Claims.build!(run) if run&.status == "claimed"
  end
end
