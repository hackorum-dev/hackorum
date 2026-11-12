module Api
  module V1
    class CommitsController < BaseController
      include TopicLookup

      def index
        topic = find_topic!(params[:id])
        lineage = context.feature?(LineageSerializer::FEATURE)
        commits = Commit.for_topic(topic.id, sources: lineage ? CommitTopic::SOURCES : CommitGroupSerializer::LINK_SOURCES)
                        .select(CommitGroupSerializer::COLUMNS.map { |name| Commit.arel_table[name] })
                        .select(CommitTopic.arel_table[:source].as("link_source"))
                        .order(:id).to_a
        groups = Commit.group_backports(commits).sort_by { |group| [ -group[:committed_at].to_r, group[:sha] ] }
        page_data = CommitPageData.new(groups, lineage: (CommitLineageData.new(topic, commits) if lineage))
        render_page(CommitGroupSerializer.brief_list(groups, context, page_data: page_data), nil)
      end
    end
  end
end
