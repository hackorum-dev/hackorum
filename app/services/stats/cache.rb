module Stats
  # A closed release never changes, so its entries never expire. The open
  # one moves with every import and LLM run; an hour of staleness is fine.
  module Cache
    # bump when a stats definition changes
    VERSION = 3
    OPEN_TTL = 1.hour

    def self.enabled? = !Rails.env.development?

    def self.fetch(release, tab, **extra, &block)
      return yield unless enabled?

      options = release.closed? ? { expires_in: nil } : { expires_in: OPEN_TTL, race_condition_ttl: 1.minute }
      Rails.cache.fetch(key(release, tab, extra), **options, &block)
    end

    def self.delete(release, tab, **extra)
      Rails.cache.delete(key(release, tab, extra))
    end

    def self.key(release, tab, extra)
      [ "release-stats", VERSION, release.major, tab.to_s, extra.sort ]
    end
    private_class_method :key
  end
end
