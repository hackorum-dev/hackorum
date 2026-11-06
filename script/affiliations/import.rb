#!/usr/bin/env ruby
# frozen_string_literal: true

# Upserts a reviewed affiliation CSV (the generate.rb format, dates ISO or
# blank). Run by hand; nothing in the repo carries this data.
#   bundle exec ruby script/affiliations/import.rb IN.csv [--dry-run] [--replace]
# --replace drops every existing row first, so a regenerated CSV is the
# whole truth.
require_relative "../../config/environment"
require "csv"

module AffiliationImport
  module_function

  def rows(path)
    CSV.read(path, headers: true).map do |r|
      { person_id: r["person_id"].to_i, company: r["company"].to_s.strip,
        since: r["since"].presence&.then { |d| Date.iso8601(d) }, until: r["until"].presence&.then { |d| Date.iso8601(d) },
        source: r["source"].presence || "manual", note: r["note"].presence }
    end
  end

  def check!(list)
    seen = {}
    list.each do |row|
      record = PersonAffiliation.new(row)
      raise ArgumentError, "bad row #{row.inspect}: #{record.errors.full_messages.join(', ')}" if record.invalid?

      key = row.values_at(:person_id, :company, :since)
      raise ArgumentError, "duplicate row #{row.inspect}" if seen.key?(key)

      seen[key] = true
    end
  end

  def apply(path, dry_run: false, replace: false)
    list = rows(path)
    check!(list)
    return list.size if dry_run

    PersonAffiliation.transaction do
      PersonAffiliation.delete_all if replace
      PersonAffiliation.upsert_all(list, unique_by: [ :person_id, :company, :since ])
    end
    list.size
  end
end

if $PROGRAM_NAME == __FILE__
  path = ARGV.find { |a| !a.start_with?("--") }
  abort("usage: import.rb IN.csv [--dry-run] [--replace]") unless path
  dry = ARGV.include?("--dry-run")
  n = begin
    AffiliationImport.apply(path, dry_run: dry, replace: ARGV.include?("--replace"))
  rescue ArgumentError => e
    abort(e.message)
  end
  puts dry ? "#{n} rows would be upserted (dry run)" : "#{n} rows upserted"
end
