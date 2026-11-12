module Api
  module V1
    # What topic rows need besides the topics, loaded once for all of them.
    class TopicPageData
      # the caller's own state, nil without a user
      attr_reader :me_data

      def initialize(topics, user: nil)
        @ids = topics.map(&:id)
        @me_data = TopicMeData.new(user, topics) if user
      end

      def mailing_lists(topic_id)
        mailing_lists_by_topic.fetch(topic_id, [])
      end

      # the Topic.commitfest_summaries entry, nil without a commitfest patch
      def commitfest(topic_id)
        commitfest_summaries[topic_id]
      end

      # the current patchset row, nil when the site shows nothing for it
      def ci(topic_id)
        ci_rows[topic_id]
      end

      private

      def mailing_lists_by_topic
        @mailing_lists_by_topic ||= @ids.empty? ? {} : TopicMailingList
          .where(topic_id: @ids).includes(:mailing_list).group_by(&:topic_id)
          .transform_values { |rows| rows.map(&:mailing_list).sort_by { |list| [ list.display_name, list.id ] } }
      end

      def commitfest_summaries
        @commitfest_summaries ||= Topic.commitfest_summaries(@ids)
      end

      def ci_rows
        @ci_rows ||= begin
          repo_state = PatchCiRepoState.current if @ids.any?
          rows = repo_state ? PatchCi::CurrentPatchsets.new(repo_state: repo_state).load(@ids) : {}
          helpers = ApplicationController.helpers
          rows.select { |_, row| helpers.ci_topic_icon(row) }
        end
      end
    end
  end
end
