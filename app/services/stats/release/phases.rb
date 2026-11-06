module Stats
  class Release
    # Time structure of one cycle for the strips: the three phase windows,
    # the zero-fill buckets, the commitfest bands and the release events.
    class Phases
      MAX_BAND_DAYS = 90
      EVENT_TAG = /\AREL_(\d+)_(BETA\d+|RC\d+|0)\z/

      attr_reader :gran

      def initialize(release, gran:)
        @release = release
        @gran = gran
      end

      # [[from, to, phase]] in order; the middle window needs the previous GA,
      # the late one needs the branch point
      def windows
        @windows ||= begin
          ga = @release.previous_ga
          bp = @release.branch_point
          finish = @release.end_at
          list = []
          if ga.nil?
            list << [ @release.start, bp || finish, :early ]
            list << [ bp, finish, :late ] if bp
          else
            list << [ @release.start, ga, :early ]
            list << [ ga, bp || finish, :middle ]
            list << [ bp, finish, :late ] if bp
          end
          list
        end
      end

      def phase_at(time)
        return windows.first.last if time < windows.first.first

        windows.find { |from, to, _| time >= from && time < to }&.last || windows.last.last
      end

      def buckets
        @buckets ||= begin
          cursor = truncate(@release.start)
          last = truncate(@release.end_at)
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
        Commitfest.where("end_date >= ? AND start_date <= ?", @release.start.to_date, @release.end_at.to_date)
                  .where("end_date - start_date <= ?", MAX_BAND_DAYS)
                  .order(:start_date)
                  .map { |cf| { from: cf.start_date, to: cf.end_date, label: cf.name } }
      end

      def events
        ReleaseTag.where(released_at: @release.start..@release.end_at)
                  .where("name ~ ?", "^REL_(#{@release.major - 1}|#{@release.major})_(BETA\\d+|RC\\d+|0)$")
                  .order(:released_at)
                  .filter_map do |tag|
          major, part = tag.name.match(EVENT_TAG).captures
          label = event_label(major.to_i, part)
          label && { at: tag.released_at, label: label }
        end
      end

      private

      def step(time)
        gran == "month" ? time.next_month : time + 7.days
      end

      def event_label(major, part)
        if major == @release.major - 1
          part == "0" ? "#{major}.0 GA" : nil
        elsif part == "0"
          "#{major}.0 GA"
        elsif part == "BETA1"
          "#{major} branched (beta1)"
        else
          part.downcase
        end
      end
    end
  end
end
