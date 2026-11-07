module Stats
  class Period
    # One run of master: from the day a major branched off (its beta1 tag,
    # when master opens for the next one) to the day the next major did.
    # Keyed and labelled by the start year: 2025 is "2025/26".
    class Cycle < Period
      attr_reader :major, :start

      # [[major, beta1 time]] ascending, from FIRST_MAJOR on
      def self.branch_points
        ReleaseTag.where("name ~ ?", '^REL_\d+_BETA1$').pluck(:name, :released_at)
                  .map { |name, at| [ name[/\d+/].to_i, at ] }
                  .select { |major, _| major >= Release::FIRST_MAJOR }.sort
      end

      # newest first; the newest branch point opens the cycle in progress
      def self.available
        points = branch_points
        return [] if points.empty?

        list = points.each_cons(2).map { |(major, from), (_, to)| new(major, from, to) }
        list << new(points.last[0], points.last[1], nil)
        list.reverse
      end

      def initialize(major, start, finish)
        @major = major
        @start = start
        @finish = finish
      end

      # the start year is unique: PostgreSQL branches once a year
      def key = start.year.to_s

      def label = "#{start.year}/#{format('%02d', (start.year + 1) % 100)}"

      def slug = "#{start.year}-#{format('%02d', (start.year + 1) % 100)}"

      def title = "#{label} cycle"

      def long_label = "the #{label} cycle"

      def noun = "cycle"

      def closed? = @finish.present?

      def end_at = @finish || now

      def range_text
        from = "#{I18n.l(start.to_date)} (#{major} branched)"
        to = closed? ? "#{I18n.l(end_at.to_date)} (#{major + 1} branched)" : "today (#{major + 1} not yet branched)"
        "Master: #{from} to #{to}"
      end
    end
  end
end
