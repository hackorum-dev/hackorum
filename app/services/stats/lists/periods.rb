module Stats
  module Lists
    module Periods
      module_function

      def truncate(gran, date)
        case gran
        when "week" then date.beginning_of_week(:monday)
        when "month" then date.beginning_of_month
        when "quarter" then date.beginning_of_quarter
        else date.beginning_of_year
        end
      end

      def step(gran, date)
        case gran
        when "week" then date + 7
        when "month" then date.next_month
        when "quarter" then date.months_since(3)
        else date.next_year
        end
      end

      def starts(gran, from, to)
        out = []
        d = truncate(gran, from)
        while d <= to
          out << d
          d = step(gran, d)
        end
        out
      end

      def label(gran, date)
        case gran
        when "week" then date.iso8601
        when "month" then date.strftime("%Y-%m")
        when "quarter" then "#{date.year} Q#{(date.month - 1) / 3 + 1}"
        else date.year.to_s
        end
      end

      def open?(gran, start, today) = start <= today && today < step(gran, start)
    end
  end
end
