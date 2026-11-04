module Topics
  class ActivityBuckets
    QUARTERLY_AFTER_MONTHS = 24

    Bucket = Struct.new(:label, :from, :to, :messages, :commits, :reverts, keyword_init: true)

    def initialize(message_times:, commit_groups:)
      @message_times = message_times.compact
      @commit_groups = commit_groups
    end

    def buckets
      return [] if @message_times.empty?

      first, last = @message_times.minmax
      last_commit = @commit_groups.filter_map { |g| g[:committed_at] }.max
      last = last_commit if last_commit && last_commit > last
      quarterly = months_between(first, last) > QUARTERLY_AFTER_MONTHS
      start_of = ->(time) { quarterly ? time.to_date.beginning_of_quarter : time.to_date.beginning_of_month }

      message_counts = @message_times.group_by(&start_of).transform_values(&:size)
      commits = @commit_groups.select { |g| g[:committed_at] }.group_by { |g| start_of.call(g[:committed_at]) }

      keys = []
      cursor = start_of.call(first)
      while cursor <= last.to_date
        keys << cursor
        cursor = cursor.next_month(quarterly ? 3 : 1)
      end

      keys.map do |key|
        landed = commits[key] || []
        Bucket.new(label: label(key, quarterly), from: key, to: key.next_month(quarterly ? 3 : 1) - 1,
                   messages: message_counts[key].to_i,
                   commits: landed.size, reverts: landed.count { |g| CommitSummary.revert?(g) })
      end
    end

    private

    def months_between(from, to)
      (to.year * 12 + to.month) - (from.year * 12 + from.month)
    end

    def label(date, quarterly)
      quarterly ? "Q#{(date.month - 1) / 3 + 1} #{date.year}" : date.strftime("%b %Y")
    end
  end
end
