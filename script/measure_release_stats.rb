#!/usr/bin/env ruby
# frozen_string_literal: true

# Uncached timing of the Overview tab, band by band, so the caching strategy
# is chosen on numbers. Usage: bundle exec ruby script/measure_release_stats.rb 19
require_relative "../config/environment"
require "benchmark"

major = ARGV.fetch(0, "19")
release = Stats::Release.find(major) or abort("no release #{major}")
overview = Stats::Release::Overview.new(release)

total = 0.0
%i[code discussion lineage reviews podiums].each do |band|
  seconds = Benchmark.realtime { overview.send(band) }
  total += seconds
  puts format("%-12s %6.2fs", band, seconds)
end
puts format("%-12s %6.2fs", "total", total)

%w[week month].each do |gran|
  seconds = Benchmark.realtime { Stats::Release::Pulse.new(release, gran: gran).to_h }
  puts format("%-12s %6.2fs", "pulse #{gran}", seconds)
end

{ "people" => Stats::Release::People, "companies" => Stats::Release::Companies, "committers" => Stats::Release::Committers }.each do |name, klass|
  seconds = Benchmark.realtime { klass.new(release).to_h }
  puts format("%-12s %6.2fs", name, seconds)
end

tgl = ::Person.find_by_email("tgl@sss.pgh.pa.us")
if tgl
  fresh = Stats::Release::Overview.new(release).to_h
  seconds = Benchmark.realtime { Stats::Release::Person.new(release, tgl, overview: fresh).to_h }
  puts format("%-12s %6.2fs", "person tgl", seconds)
else
  puts "person tgl   skipped (not found)"
end
