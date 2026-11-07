#!/usr/bin/env ruby
# frozen_string_literal: true

# Uncached timing of every tab, band by band for the Overview, so caching
# decisions rest on numbers. Usage: bundle exec ruby script/measure_stats.rb [kind] [key]
# e.g. "release 19", "year 2025", "cycle 2025"
require_relative "../config/environment"
require "benchmark"

kind = ARGV.fetch(0, "release")
key = ARGV.fetch(1, "19")
period = Stats::Period.lookup(kind, key) or abort("usage: measure_stats.rb <kind> <key> (e.g. release 19); no #{kind} #{key}")
overview = Stats::Period::Overview.new(period)

total = 0.0
%i[code discussion lineage reviews podiums].each do |band|
  seconds = Benchmark.realtime { overview.send(band) }
  total += seconds
  puts format("%-12s %6.2fs", band, seconds)
end
puts format("%-12s %6.2fs", "total", total)

%w[week month].each do |gran|
  seconds = Benchmark.realtime { Stats::Period::Pulse.new(period, gran: gran).to_h }
  puts format("%-12s %6.2fs", "pulse #{gran}", seconds)
end

{ "people" => Stats::Period::People, "companies" => Stats::Period::Companies, "committers" => Stats::Period::Committers }.each do |name, klass|
  next if name == "companies" && !period.companies?

  seconds = Benchmark.realtime { klass.new(period).to_h }
  puts format("%-12s %6.2fs", name, seconds)
end

tgl = ::Person.find_by_email("tgl@sss.pgh.pa.us")
if tgl
  fresh = Stats::Period::Overview.new(period).to_h
  seconds = Benchmark.realtime { Stats::Period::Person.new(period, tgl, overview: fresh).to_h }
  puts format("%-12s %6.2fs", "person tgl", seconds)
else
  puts "person tgl   skipped (not found)"
end
