require "digest"

class SearchResultCache
  CACHE_VERSION = "v1"
  LONGPAGE_SIZE = 1000
  CACHE_TTL = 6.hours
  CACHE_THRESHOLD_SECONDS = 0.4

  def initialize(query:, scope:, viewing_since:, longpage: 0, cache: Rails.cache)
    @query = query.to_s
    @scope = scope.to_s
    @viewing_since = viewing_since
    @longpage = [ longpage.to_i, 0 ].max
    @cache = cache
  end

  def fetch
    watermarks = compute_watermarks
    cached = read_cached(watermarks)
    return cached if cached

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    entries = yield(LONGPAGE_SIZE, offset_for_longpage)
    duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    payload = serialize_entries(entries).merge(watermarks:, cached_at: Time.current)

    if duration > CACHE_THRESHOLD_SECONDS
      write_cached(watermarks, payload)
    end

    payload
  end

  private

  def offset_for_longpage
    LONGPAGE_SIZE * @longpage
  end

  def read_cached(watermarks)
    @cache.read(cache_key(watermarks))
  end

  def write_cached(watermarks, payload)
    @cache.write(cache_key(watermarks), payload, expires_in: CACHE_TTL)
  end

  def cache_key(watermarks)
    watermark_part = watermarks.sort_by { |k, _| k.to_s }.map { |k, v| "#{k}=#{v || 0}" }.join(":")
    query_hash = Digest::SHA1.hexdigest(@query)
    key  = [
      "search",
      CACHE_VERSION,
      "scope", @scope,
      "q", query_hash,
      "wm", watermark_part,
      "lp", @longpage
    ].join(":")
    key
  end

  def serialize_entries(entries)
    {
      entries: entries.map do |row|
        {
          id: row.id,
          last_activity: row.try(:last_activity)&.to_time || row.try(:created_at)&.to_time
        }
      end
    }
  end

  def compute_watermarks
    case @scope
    when "title_body"
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(@query)}%"
      title_max = Topic.where("title ILIKE ?", pattern)
                       .where("created_at <= ?", @viewing_since)
                       .maximum(:id) || 0
      body_max = Message.where("body ILIKE ?", pattern)
                        .where("created_at <= ?", @viewing_since)
                        .maximum(:id) || 0
      { title_max_id: title_max, body_max_id: body_max }
    else
      {}
    end
  end
end
