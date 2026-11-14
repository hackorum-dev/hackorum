#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../config/environment"

started = Time.current
Stats::Lists::Builder.new.run!
puts format("list stats built in %.1fs", Time.current - started)

if Stats::Cache.enabled?
  params = Stats::ListsParams.new(params: {})
  Stats::Cache.delete_lists(:volume, params.cache_key)
  Stats::Cache.fetch_lists(:volume, params.cache_key) { Stats::Lists::Volume.new(params).to_h }

  newcomers = Stats::ListsParams.new(params: {})
  Stats::Cache.delete_lists(:newcomers, newcomers.newcomers_cache_key)
  Stats::Cache.fetch_lists(:newcomers, newcomers.newcomers_cache_key) { Stats::Lists::Newcomers.new(newcomers).to_h }

  regulars = Stats::ListsParams.new(params: {}, default_years: 3)
  regulars_key = regulars.regulars_cache_key(nil, nil)
  Stats::Cache.delete_lists(:regulars, regulars_key)
  Stats::Cache.fetch_lists(:regulars, regulars_key) { Stats::Lists::Regulars.new(regulars).to_h }
end
