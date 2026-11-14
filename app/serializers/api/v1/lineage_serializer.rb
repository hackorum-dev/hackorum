module Api
  module V1
    # The finished lineage run of a thread: what a model wrote about its patchsets.
    class LineageSerializer < BaseSerializer
      STEP_COLUMNS = %i[parent_message_id step_kind confidence reason].freeze
      RUN_COLUMNS = %i[id topic_id model finished_at story].freeze

      # the run PatchsetRun.current_for picks, without the columns nothing here gives out
      def self.current_run(topic_id, columns: RUN_COLUMNS)
        PatchsetRun.done.where(topic_id: topic_id).newest_first.select(columns).first
      end

      def self.step(row)
        STEP_COLUMNS.index_with { |name| row.public_send(name) }
      end

      def brief
        {
          run: { id: record.id, model: record.model, finished_at: record.finished_at },
          story: story,
          steps: steps
        }
      end

      private

      def story
        record.story.to_s.lines.map(&:strip).reject(&:empty?).map do |line|
          {
            text: line,
            message_ids: line.scan(LineageHelper::MSG_TOKEN).flatten.map(&:to_i).uniq,
            commit_shas: line.scan(LineageHelper::COMMIT_TOKEN).flatten.uniq
          }
        end
      end

      def steps
        rows = record.lineages.joins(:message).order("messages.created_at", "messages.id")
        rows.map { |row| { message_id: row.message_id, **self.class.step(row) } }
      end
    end
  end
end
