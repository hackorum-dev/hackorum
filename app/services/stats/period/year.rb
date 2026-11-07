module Stats
  class Period
    # A calendar year, January to December, across every branch.
    class Year < Period
      FIRST_YEAR = 2017

      attr_reader :year

      def self.available
        (FIRST_YEAR..Time.current.year).map { |y| new(y) }.reverse
      end

      def initialize(year)
        @year = year.to_i
      end

      def key = year.to_s

      def label = year.to_s

      def slug = year.to_s

      def noun = "year"

      def start = Time.zone.local(year)

      def closed? = Time.zone.local(year + 1) <= now

      def end_at = closed? ? Time.zone.local(year + 1) : now

      def range_text
        "Year: #{I18n.l(start.to_date)} to #{closed? ? I18n.l(last_date) : 'today'}"
      end
    end
  end
end
