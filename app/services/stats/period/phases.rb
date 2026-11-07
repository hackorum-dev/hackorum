module Stats
  class Period
    # Time structure of one period for the strips: the phase windows, the
    # zero-fill buckets, the commitfest bands and the release events.
    class Phases
      MAX_BAND_DAYS = 90

      attr_reader :gran

      def initialize(period, gran:)
        @period = period
        @gran = gran
      end

      def windows = @period.windows

      def phase_at(time) = @period.phase_at(time)

      def events = @period.events

      def buckets
        @buckets ||= begin
          cursor = truncate(@period.start)
          last = truncate(@period.end_at - 1.second)
          list = []
          while cursor <= last
            list << { start: cursor, label: label(cursor), phase: phase_at(cursor) }
            cursor = step(cursor)
          end
          list
        end
      end

      def truncate(time)
        gran == "month" ? time.beginning_of_month : time.beginning_of_week(:monday)
      end

      def label(time)
        gran == "month" ? time.strftime("%b %Y") : time.strftime("%Y-%m-%d")
      end

      def bands
        Commitfest.where("end_date >= ? AND start_date <= ?", @period.start.to_date, (@period.end_at - 1.second).to_date)
                  .where("end_date - start_date <= ?", MAX_BAND_DAYS)
                  .order(:start_date)
                  .map { |cf| { from: cf.start_date, to: cf.end_date, label: cf.name } }
      end

      private

      def step(time)
        gran == "month" ? time.next_month : time + 7.days
      end
    end
  end
end
