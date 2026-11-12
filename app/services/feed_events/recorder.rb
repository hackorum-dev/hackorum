module FeedEvents
  # A row is built at the call and inserted once the caller's transactions
  # have committed, so no id is taken before its row can be read.
  # A crash between that commit and the insert loses the event:
  # script/backfill_feed_events.rb adds what is missing.
  # Never raises: a lost feed row must not fail the writer that called.
  class Recorder
    class << self
      def message_received(message)
        record(FeedEvent::MESSAGE_RECEIVED, { message_id: message&.id }) { message_row(message) }
      end

      def patchset_posted(message)
        record(FeedEvent::PATCHSET_POSTED, { message_id: message&.id }) { message_row(message) }
      end

      def branch_created(branch)
        record(FeedEvent::BRANCH_CREATED, { patch_branch_id: branch&.id }) do
          next if branch.lineage_only

          message = Message.where(id: branch.message_id).pick(:id, :sender_person_id)
          next unless message

          { message_id: message[0], author_person_id: message[1], patch_branch_id: branch.id,
            occurred_at: branch.attempted_at || branch.created_at }
        end
      end

      # replace: the run was recorded with another verdict, it is reported again
      def ci_completed(run, replace: false)
        record(FeedEvent::CI_COMPLETED, { patch_ci_run_id: run&.id }, replace: replace) do
          next unless run.terminal?

          message = Message.joins(:patch_branch).where(patch_branches: { id: run.patch_branch_id })
                           .pick(:id, :sender_person_id)
          next unless message

          previous = previous_status(run)
          { message_id: message[0], author_person_id: message[1],
            patch_branch_id: run.patch_branch_id, patch_ci_run_id: run.id,
            occurred_at: run.completed_at || Time.current,
            first_run: previous.nil?, previous_status: previous,
            verdict_changed: replace || previous != run.status }
        end
      end

      def message_redated(message)
        ids = { message_id: message&.id }
        occurred_at = guarded("redate", ids) { message.created_at }
        return unless occurred_at

        after_commit("redate", ids) do
          FeedEvent.where(ids).where(event_type: FeedEvent::MESSAGE_TYPES).update_all(occurred_at: occurred_at)
        end
      end

      private

      def message_row(message)
        { message_id: message.id, author_person_id: message.sender_person_id, occurred_at: message.created_at }
      end

      def previous_status(run)
        PatchCiRun.terminal.where(patch_branch_id: run.patch_branch_id).where.not(id: run.id)
                  .order(created_at: :desc, id: :desc).pick(:status)
      end

      def record(event_type, ids, replace: false)
        row = guarded(event_type, ids) { yield }
        return unless row

        row = row.merge(event_type: event_type)
        after_commit(event_type, ids) do
          FeedEvent.where(ids).where(event_type: event_type).delete_all if replace
          FeedEvent.insert_all([ row ], record_timestamps: false)
        end
      end

      def after_commit(what, ids)
        guarded(what, ids) do
          ActiveRecord.after_all_transactions_commit do
            # a transaction can still be open here in tests: a savepoint keeps a failed statement to itself
            guarded(what, ids) { FeedEvent.transaction(requires_new: true) { yield } }
          end
        end
        nil
      end

      def guarded(what, ids)
        yield
      rescue StandardError => e
        Rails.logger.warn("feed event #{what} #{ids.inspect} not recorded: #{e.class}: #{e.message}")
        nil
      end
    end
  end
end
