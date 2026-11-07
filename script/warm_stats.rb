#!/usr/bin/env ruby
# frozen_string_literal: true

# Rebuilds the stats cache for every period so the first visitor after an
# import does not pay for it. Closed periods are rebuilt too: a prompt or
# parser change can move their numbers.
require_relative "../config/environment"

abort("stats cache is off in #{Rails.env}, nothing to warm") unless Stats::Cache.enabled?

Stats::Period.all.each do |period|
  { [ :overview, {} ] => proc { Stats::Period::Overview.new(period).to_h },
    [ :pulse, { gran: "week" } ] => proc { Stats::Period::Pulse.new(period, gran: "week").to_h },
    [ :pulse, { gran: "month" } ] => proc { Stats::Period::Pulse.new(period, gran: "month").to_h },
    [ :people, {} ] => proc { Stats::Period::People.new(period).to_h },
    [ :companies, {} ] => proc { Stats::Period::Companies.new(period).to_h },
    [ :committers, {} ] => proc { Stats::Period::Committers.new(period).to_h } }.each do |(tab, extra), build|
    next if tab == :companies && !period.companies?

    Stats::Cache.delete(period, tab, **extra)
    started = Time.current
    Stats::Cache.fetch(period, tab, **extra, &build)
    puts format("%s %s %s %s %.1fs", period.kind, period.label, tab, extra.values.join, Time.current - started)
  end
end
