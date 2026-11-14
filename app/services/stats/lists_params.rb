module Stats
  # list selection, range and granularity of the list pages; bad input
  # falls back to the defaults
  class ListsParams
    GRANS = %w[week month quarter year].freeze
    EARLIEST = Date.new(1997, 1, 1)
    WEEK_MAX_DAYS = 3 * 366

    attr_reader :all_lists, :lists, :from, :to, :gran, :today

    def initialize(params:, today: Date.current, default_years: 10)
      @all_lists = MailingList.where.not(stats_bit: nil).order(:stats_bit).to_a
      @default = @all_lists.select(&:stats_default?).presence || @all_lists
      @today = today
      wanted = params[:lists].is_a?(Array) ? params[:lists].map(&:to_s) : params[:lists].to_s.split(",").map(&:strip)
      @lists = @all_lists.select { |l| wanted.include?(l.identifier) }.presence || @default

      from_span = parse(params[:from])
      to_span = parse(params[:to])
      default_from = Date.new(today.year - default_years + 1, 1, 1)
      default_to = today.end_of_month
      @explicit_range = !!(from_span && to_span)
      @from = from_span&.first || default_from
      @to = to_span&.last || default_to
      if @from > @to
        if from_span && to_span
          @from, @to = to_span.first, from_span.last
        else
          @from, @to = default_from, default_to
          @explicit_range = false
        end
      end
      @from = [ @from, EARLIEST ].max
      @to = [ @to, default_to ].min
      if @from > @to
        @from, @to = default_from, default_to
        @explicit_range = false
      end

      @gran = params[:gran].to_s.presence_in(GRANS) || "month"
      @gran = "month" if @gran == "week" && (@to - @from) > WEEK_MAX_DAYS
    end

    def explicit_range? = @explicit_range

    # links between tabs: each tab keeps its own default range unless the user set one
    def tab_query
      q = { lists: lists.map(&:identifier).join(",") }
      q.merge!(from: from.strftime("%Y-%m"), to: to.strftime("%Y-%m")) if explicit_range?
      q
    end

    def preset_query(years)
      from = years ? (today.beginning_of_month << (12 * years - 1)) : EARLIEST
      to_query.merge(from: from.strftime("%Y-%m"), to: today.strftime("%Y-%m"))
    end

    def week_allowed? = (to - from) <= WEEK_MAX_DAYS

    def mask = lists.sum { |l| 1 << l.stats_bit }

    def default_lists? = lists == @default

    def to_query
      { lists: lists.map(&:identifier).join(","), from: from.strftime("%Y-%m"), to: to.strftime("%Y-%m"), gran: gran }
    end

    def cache_key = [ mask, from.iso8601, to.iso8601, gran ]

    def newcomers_cache_key = [ mask, from.iso8601, to.iso8601 ]

    def regulars_cache_key(score, at)
      month = at.to_s.match(/\A(\d{4})-(\d{1,2})\z/) { |m| format("%04d-%02d", m[1].to_i, m[2].to_i) }
      [ mask, from.iso8601, to.iso8601, score.presence_in(Stats::Lists::Monthly::SCORES) || "threads", month.to_s ]
    end

    private

    def parse(value)
      case value.to_s
      when /\A(\d{4})\z/
        date = Date.new(Regexp.last_match(1).to_i, 1, 1)
        [ date, date.end_of_year ]
      when /\A(\d{4})-(\d{1,2})\z/
        date = Date.new(Regexp.last_match(1).to_i, Regexp.last_match(2).to_i, 1)
        [ date, date.end_of_month ]
      end
    rescue Date::Error
      nil
    end
  end
end
