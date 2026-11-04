module Topics
  class Chapters
    MIN_MESSAGES = 60
    GAP = 45.days
    MAX_SIZE = 150
    SPLIT_TARGET = 100

    Chapter = Struct.new(:index, :messages, :commits, keyword_init: true) do
      def size = messages.size
      def first_at = messages.first.created_at
      def last_at = messages.last.created_at
      def reverts = commits.count { |g| CommitSummary.revert?(g) }

      def label
        from = first_at.to_date
        to = last_at.to_date
        return from.year.to_s if from.year == to.year && from.month == 1 && to.month == 12
        return from.strftime("%b %Y") if from.year == to.year && from.month == to.month
        return "#{from.strftime('%b')} - #{to.strftime('%b %Y')}" if from.year == to.year
        "#{from.strftime('%b %Y')} - #{to.strftime('%b %Y')}"
      end
    end

    def initialize(messages, commit_groups: [])
      @messages = messages
      @commit_groups = commit_groups
    end

    def chapters
      @chapters ||= begin
        if @messages.size < MIN_MESSAGES
          []
        else
          runs = split_by_gap(@messages).flat_map { |run| run.size > MAX_SIZE ? split_by_month(run) : [ run ] }
          starts = runs.map { |run| run.first.created_at }
          runs.each_with_index.map do |run, i|
            Chapter.new(index: i, messages: run, commits: commits_between(i.zero? ? nil : starts[i], starts[i + 1]))
          end
        end
      end
    end

    def index_of(message_id)
      @index_by_id ||= chapters.each_with_object({}) do |chapter, map|
        chapter.messages.each { |m| map[m.id] = chapter.index }
      end
      @index_by_id[message_id]
    end

    private

    def split_by_gap(messages)
      messages.chunk_while { |a, b| b.created_at - a.created_at < GAP }.to_a
    end

    def split_by_month(run)
      months = run.chunk_while { |a, b| a.created_at.beginning_of_month == b.created_at.beginning_of_month }
      months.each_with_object([]) do |month, out|
        if out.any? && out.last.size + month.size <= SPLIT_TARGET
          out.last.concat(month)
        else
          out << month.dup
        end
      end
    end

    def commits_between(from, to)
      @commit_groups.select do |g|
        at = g[:committed_at]
        at && (from.nil? || at >= from) && (to.nil? || at < to)
      end
    end
  end
end
