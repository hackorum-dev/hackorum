module Stats
  # A closed period never changes, so its entries never expire. An open one
  # moves with every import and LLM run; an hour of staleness is fine.
  module Cache
    # bump when a stats definition changes
    VERSION = 5
    OPEN_TTL = 1.hour

    def self.enabled? = !Rails.env.development?

    def self.fetch(period, tab, **extra, &block)
      return yield unless enabled?

      options = period.closed? ? { expires_in: nil } : { expires_in: OPEN_TTL, race_condition_ttl: 1.minute }
      Rails.cache.fetch(key(period, tab, extra), **options, &block)
    end

    def self.delete(period, tab, **extra)
      Rails.cache.delete(key(period, tab, extra))
    end

    # a trend always ends in an open period
    def self.fetch_trend(kind, &block)
      return yield unless enabled?

      Rails.cache.fetch(trend_key(kind), expires_in: OPEN_TTL, race_condition_ttl: 1.minute, &block)
    end

    def self.delete_trend(kind)
      Rails.cache.delete(trend_key(kind))
    end

    # list pages always end in an open period
    def self.fetch_lists(tab, key, &block)
      return yield unless enabled?

      Rails.cache.fetch(lists_key(tab, key), expires_in: OPEN_TTL, race_condition_ttl: 1.minute, &block)
    end

    def self.delete_lists(tab, key)
      Rails.cache.delete(lists_key(tab, key))
    end

    def self.lists_key(tab, key) = [ "stats", VERSION, "lists", tab.to_s, *key ]
    private_class_method :lists_key

    def self.trend_key(kind) = [ "stats", VERSION, "trend", kind.to_s ]
    private_class_method :trend_key

    def self.key(period, tab, extra)
      [ "stats", VERSION, period.kind.to_s, period.key, tab.to_s, extra.sort ]
    end
    private_class_method :key
  end
end
