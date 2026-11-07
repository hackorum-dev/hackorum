module Stats
  # A closed period never changes, so its entries never expire. An open one
  # moves with every import and LLM run; an hour of staleness is fine.
  module Cache
    # bump when a stats definition changes
    VERSION = 4
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

    def self.key(period, tab, extra)
      [ "stats", VERSION, period.kind.to_s, period.key, tab.to_s, extra.sort ]
    end
    private_class_method :key
  end
end
