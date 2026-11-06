module Stats
  # The Pulse tab's query params, sanitized once; gran is interpolated into
  # date_trunc, so it is a whitelist, not a cast.
  class PulseParams
    GRANS = %w[week month].freeze
    GROUPS = {
      "all" => nil,
      "code" => %w[commits threads_landing],
      "discussion" => %w[messages new_threads patch_submissions active_people first_time_posters]
    }.freeze
    ALL_KEYS = %w[commits messages new_threads patch_submissions active_people first_time_posters threads_landing].freeze

    attr_reader :gran, :group

    def initialize(params:)
      @gran = params[:gran].to_s.presence_in(GRANS) || GRANS.first
      @group = params[:group].to_s.presence_in(GROUPS.keys) || "all"
    end

    def keys
      GROUPS[group] || ALL_KEYS
    end
  end
end
