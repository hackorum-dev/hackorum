class RefreshCommitAggregatesForLlmLinks < ActiveRecord::Migration[8.0]
  def up
    CommitTopic.where(source: "llm").distinct.pluck(:topic_id).each_slice(1000) do |ids|
      Topic.refresh_commit_aggregates!(ids)
    end
  end

  def down
  end
end
