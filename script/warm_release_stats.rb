#!/usr/bin/env ruby
# frozen_string_literal: true

# Rebuilds the release-wide stats cache so the first visitor after an import
# does not pay for it. Closed releases are rebuilt too: a prompt or parser
# change can move their numbers.
require_relative "../config/environment"

abort("release stats cache is off in #{Rails.env}, nothing to warm") unless Stats::Cache.enabled?

Stats::Release.available.each do |release|
  { [ :overview, {} ] => proc { Stats::Release::Overview.new(release).to_h },
    [ :pulse, { gran: "week" } ] => proc { Stats::Release::Pulse.new(release, gran: "week").to_h },
    [ :pulse, { gran: "month" } ] => proc { Stats::Release::Pulse.new(release, gran: "month").to_h },
    [ :people, {} ] => proc { Stats::Release::People.new(release).to_h },
    [ :companies, {} ] => proc { Stats::Release::Companies.new(release).to_h },
    [ :committers, {} ] => proc { Stats::Release::Committers.new(release).to_h } }.each do |(tab, extra), build|
    Stats::Cache.delete(release, tab, **extra)
    started = Time.current
    Stats::Cache.fetch(release, tab, **extra, &build)
    puts format("%s %s %s %.1fs", release.label, tab, extra.values.join, Time.current - started)
  end
end
