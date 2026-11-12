module Api
  module V1
    # What the events of one page show, loaded once per event type.
    class EventPageData
      BRANCH_COLUMNS = BranchSerializer::REF_COLUMNS

      def initialize(events, context)
        @events = events
        @context = context
      end

      def topic(event)
        topics[event.current_topic_id]
      end

      def author(event)
        people[event.author_person_id]
      end

      # the serialized record of the event, nil when it is gone
      def payload(event)
        case event.event_type
        when FeedEvent::MESSAGE_RECEIVED then messages[event.message_id]
        when FeedEvent::PATCHSET_POSTED then patchsets[event.message_id]
        when FeedEvent::BRANCH_CREATED then branches[event.patch_branch_id]
        when FeedEvent::CI_COMPLETED then ci_run(event)
        end
      end

      private

      def ci_run(event)
        ci_runs[event.patch_ci_run_id]&.merge(first_run: event.first_run, previous_status: event.previous_status)
      end

      def ids(event_type, column)
        @events.select { |event| event.event_type == event_type }.map(&column).uniq
      end

      def topics
        @topics ||= begin
          ids = @events.map(&:current_topic_id).uniq
          ids.empty? ? {} : Topic.where(id: ids).select(:id, :slug, :title).index_by(&:id)
        end
      end

      def people
        @people ||= begin
          ids = @events.filter_map(&:author_person_id).uniq
          ids.empty? ? {} : Person.where(id: ids).preload(PersonSerializer::PRELOAD).index_by(&:id)
        end
      end

      def messages
        @messages ||= begin
          ids = ids(FeedEvent::MESSAGE_RECEIVED, :message_id)
          records = ids.empty? ? [] : MessageSerializer.load(Message.where(id: ids), body: "none").to_a
          MessageSerializer.brief_list(records, @context, body: "none").index_by { |row| row[:id] }
        end
      end

      def patchsets
        @patchsets ||= begin
          ids = ids(FeedEvent::PATCHSET_POSTED, :message_id)
          records = ids.empty? ? [] : PatchsetSerializer.load(Message.where(id: ids)).to_a
          PatchsetSerializer.brief_list(records, @context).index_by { |row| row[:message_id] }
        end
      end

      def branches
        @branches ||= begin
          ids = ids(FeedEvent::BRANCH_CREATED, :patch_branch_id)
          ids.empty? ? {} : load_branches(ids)
        end
      end

      def load_branches(ids)
        repo_state = PatchCiRepoState.current
        rows = PatchCi::BranchRows.new(repo_state: repo_state)
        records = rows.load(rows.health.with_reason(PatchBranch.where(id: ids)))
        BranchSerializer.brief_list(records, @context, repo_state: repo_state).index_by { |row| row[:id] }
      end

      def ci_runs
        @ci_runs ||= begin
          ids = ids(FeedEvent::CI_COMPLETED, :patch_ci_run_id)
          ids.empty? ? {} : load_ci_runs(ids)
        end
      end

      def load_ci_runs(ids)
        runs = PatchCiRun.where(id: ids).select(*PatchCiRun.list_columns).to_a
        branches = PatchBranch.where(id: runs.map(&:patch_branch_id).uniq)
                              .select(*BRANCH_COLUMNS).index_by(&:id)
        runs.each_with_object({}) do |run, found|
          branch = branches[run.patch_branch_id]
          next unless branch

          found[run.id] = CiRunSerializer.new(run, @context).brief
                                         .merge(branch: BranchSerializer.new(branch, @context).ref)
        end
      end
    end
  end
end
