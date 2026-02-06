# frozen_string_literal: true

module Search
  # Parses date strings for search queries.
  # Supports absolute dates (2024-01-01, 2024-01, 2024) and relative dates (today, yesterday, 7d, 2w, 3m, 1y)
  class DateParser
    RELATIVE_PATTERNS = {
      /\Atoday\z/i => -> { Time.current.beginning_of_day },
      /\Ayesterday\z/i => -> { 1.day.ago.beginning_of_day },
      /\A(\d+)d\z/i => ->(n) { n.to_i.days.ago },
      /\A(\d+)w\z/i => ->(n) { n.to_i.weeks.ago },
      /\A(\d+)m\z/i => ->(n) { (n.to_i * 30).days.ago },
      /\A(\d+)y\z/i => ->(n) { (n.to_i * 365).days.ago }
    }.freeze

    def initialize(value)
      @value = value.to_s.strip
    end

    def parse
      return nil if @value.blank?

      parse_relative || parse_absolute
    end

    def valid?
      parse.present?
    end

    private

    def parse_relative
      RELATIVE_PATTERNS.each do |pattern, handler|
        match = @value.match(pattern)
        next unless match

        if match.captures.empty?
          return handler.call
        else
          return handler.call(match[1])
        end
      end

      nil
    end

    def parse_absolute
      case @value
      when /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/
        # Full ISO timestamp: 2024-01-15T10:30:00
        Time.zone.parse(@value)
      when /\A(\d{4})-(\d{2})-(\d{2})\z/
        # Full date: 2024-01-01
        Time.zone.parse("#{@value} 00:00:00")
      when /\A(\d{4})-(\d{2})\z/
        # Month only: 2024-01
        Time.zone.parse("#{@value}-01 00:00:00")
      when /\A(\d{4})\z/
        # Year only: 2024
        Time.zone.parse("#{@value}-01-01 00:00:00")
      else
        # Try a generic parse as last resort
        Time.zone.parse(@value)
      end
    rescue ArgumentError, TypeError
      nil
    end
  end
end
