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
    [ :committers, {} ] => proc { Stats::Period::Committers.new(period).to_h },
    [ :first_timers, {} ] => proc { Stats::Period::FirstTimers.new(period).count } }.each do |(tab, extra), build|
    next if tab == :companies && !period.companies?

    Stats::Cache.delete(period, tab, **extra)
    started = Time.current
    Stats::Cache.fetch(period, tab, **extra, &build)
    puts format("%s %s %s %s %.1fs", period.kind, period.label, tab, extra.values.join, Time.current - started)
  end
end

Stats::Trend::TITLES.each_key do |kind|
  Stats::Cache.delete_trend(kind)
  started = Time.current
  Stats::Cache.fetch_trend(kind) { Stats::Trend.new(kind).to_h }
  puts format("trend %s %.1fs", kind, Time.current - started)
end

selections = [ {} ] + MailingList.where.not(stats_bit: nil).order(:stats_bit).map { |l| { lists: l.identifier } }
selections.each do |sel|
  params = Stats::ListsParams.new(params: sel)
  Stats::Cache.delete_lists(:volume, params.cache_key)
  started = Time.current
  Stats::Cache.fetch_lists(:volume, params.cache_key) { Stats::Lists::Volume.new(params).to_h }
  puts format("lists volume %s %.1fs", sel[:lists] || "default", Time.current - started)
end

[ [ :newcomers, proc { |p| p.newcomers_cache_key }, proc { |p| Stats::Lists::Newcomers.new(p).to_h } ],
  [ :regulars, proc { |p| p.regulars_cache_key(nil, nil) }, proc { |p| Stats::Lists::Regulars.new(p).to_h } ] ].each do |tab, key, build|
  params = Stats::ListsParams.new(params: {}, default_years: tab == :regulars ? 3 : 10)
  Stats::Cache.delete_lists(tab, key.call(params))
  started = Time.current
  Stats::Cache.fetch_lists(tab, key.call(params)) { build.call(params) }
  puts format("lists %s %.1fs", tab, Time.current - started)
end
