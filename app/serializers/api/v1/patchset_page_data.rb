module Api
  module V1
    # What patchset rows need besides the messages, loaded once for all of them.
    class PatchsetPageData
      def initialize(messages)
        @ids = messages.map(&:id)
        @topic_ids = messages.map(&:topic_id).uniq
      end

      # the row of the current lineage run of the thread, nil without one
      def step(message_id)
        steps[message_id]
      end

      # 1-based position in the thread
      def number(message_id)
        numbers[message_id]
      end

      def files(message_id)
        files_by_message.fetch(message_id, [])
      end

      def changed_paths(message_id)
        paths_by_message.fetch(message_id, [])
      end

      def branch(message_id)
        branches[message_id]
      end

      private

      def numbers
        @numbers ||= @ids.empty? ? {} : begin
          threads = ThreadNumber.of(@topic_ids).select(:id, ThreadNumber::SQL.as("number"))
          Message.from(threads, :numbered).where("numbered.id IN (?)", @ids).pluck("numbered.id", "numbered.number").to_h
        end
      end

      # the files of the download archive
      def files_by_message
        @files_by_message ||= @ids.empty? ? {} : Attachment
          .metadata.where(message_id: @ids).order(:id).select(&:patch_submission_candidate?).group_by(&:message_id)
      end

      def paths_by_message
        @paths_by_message ||= @ids.empty? ? {} : PatchSubmissionFile
          .where(message_id: @ids).order(:path).pluck(:message_id, :path)
          .group_by(&:first).transform_values { |rows| rows.map(&:last) }
      end

      def steps
        @steps ||= @ids.empty? ? {} : PatchsetLineage
          .where(patchset_run_id: current_runs, message_id: @ids)
          .select(:id, :message_id, *LineageSerializer::STEP_COLUMNS).index_by(&:message_id)
      end

      # the newest finished run of each thread, as PatchsetRun.current_for picks it
      def current_runs
        PatchsetRun.done.where(topic_id: @topic_ids).order(:topic_id, created_at: :desc, id: :desc)
                   .select("DISTINCT ON (patchset_runs.topic_id) patchset_runs.id").map(&:id)
      end

      def branches
        @branches ||= @ids.empty? ? {} : PatchBranch
          .where(message_id: @ids, lineage_only: false)
          .select(:message_id, *BranchSerializer::REF_COLUMNS).index_by(&:message_id)
      end
    end
  end
end
