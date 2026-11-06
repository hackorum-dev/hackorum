module Stats
  # The People tab's query params, sanitized once. rank picks the default
  # sort and the top-N chart; sort/dir order the table.
  class PeopleParams
    RANKS = %w[credits authored reviewed messages].freeze
    COMMITTERS = %w[included excluded].freeze
    COLUMNS = %w[credits authored reviewed committed messages threads].freeze
    DIRS = %w[desc asc].freeze
    TOP = 20

    attr_reader :rank, :committers, :sort, :dir

    def initialize(params:)
      @rank = params[:rank].to_s.presence_in(RANKS) || RANKS.first
      @committers = params[:committers].to_s.presence_in(COMMITTERS) || COMMITTERS.first
      @sort = params[:sort].to_s.presence_in(COLUMNS) || @rank
      @dir = params[:dir].to_s.presence_in(DIRS) || DIRS.first
      @all = params[:all].to_s == "1"
    end

    def all? = @all

    def active_params
      { rank: rank, committers: committers, sort: sort, dir: dir, all: (@all ? "1" : nil) }.compact
    end

    def value(row, key)
      key == "credits" ? row[:authored] + row[:reviewed] : row[key.to_sym]
    end

    # ties go by ascending id in either direction
    def order_rows(rows, by: sort, direction: dir)
      rows = rows.reject { |r| r[:committer] } if committers == "excluded"
      sign = direction == "desc" ? -1 : 1
      rows.sort_by { |r| [ sign * value(r, by), r[:id] ] }
    end

    def top_rows(rows)
      order_rows(rows, by: rank, direction: "desc").first(TOP)
    end
  end
end
