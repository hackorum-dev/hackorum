#!/usr/bin/env ruby
# frozen_string_literal: true

# Writes a candidate affiliation CSV for review. Inputs and output live
# outside the repo: affiliations are personal data and must stay removable.
#   bundle exec ruby script/affiliations/generate.rb OUT.csv [--domains DOMAINS.yml] [--percona percona_activity.py] [--exclude EXCLUDE.txt]
# DOMAINS.yml maps an email domain to a company name, e.g.
#   enterprisedb.com: EDB
# A domain also matches its subdomains (jp.fujitsu.com hits fujitsu.com).
# --percona reads percona-pg-activity's percona_activity.py as it is:
# COMPANY_DOMAINS, COMPANY_NAME_OVERRIDES (people known by name), the dated
# COMPANY_NAME_HISTORY and NAME_ALIASES. DOMAINS.yml wins over its domains.
# EXCLUDE.txt holds one person_id per line; those people are skipped, so a
# removal request survives re-runs. Keep it outside the repo too.
require_relative "../../config/environment"
require "csv"
require "yaml"

module AffiliationGenerate
  HEADER = %w[person_id name email company since until source note].freeze
  # the same employer spelled differently across sources
  COMPANY_ALIASES = {
    "enterprisedb" => "EDB", "amazon web services" => "Amazon", "aws" => "Amazon",
    "crunchy data solutions" => "Crunchy Data", "ntt data" => "NTT DATA", "nttdata" => "NTT DATA",
    "sra oss" => "SRA OSS", "timescale" => "Tiger Data (Timescale)", "tiger data" => "Tiger Data (Timescale)",
    "postgrespro" => "Postgres Professional", "highgo" => "Highgo Software", "highgo software inc" => "Highgo Software"
  }.freeze
  COMPANY_SUFFIX = /\s*(,|\s)\s*(inc|inc\.|llc|ltd|ltd\.|gmbh|k\.k\.|co\.|corp|corp\.|corporation|limited)\s*\z/i

  Percona = Struct.new(:domains, :overrides, :history, :aliases, keyword_init: true)

  module_function

  def rows(domains, exclude = Set.new, percona: nil)
    out = {}
    ContributorMembership.where.not(person_id: nil).where.not(company: [ nil, "" ])
                         .where.not(person_id: exclude.to_a)
                         .includes(person: :default_alias).find_each do |m|
      add(out, m.person, canonical(m.company), "contributors_page")
    end
    named(percona, exclude) { |person, company, since, till, note| add(out, person, company, "manual", since: since, till: till, note: note) } if percona
    aliases(exclude).find_each do |a|
      company = company_for_email(domains, a.email)
      add(out, a.person, canonical(company), "domain") if company && a.person
    end
    out.values
  end

  def aliases(exclude)
    Alias.where("sender_count > 0 OR person_id IN (?)", CommitPerson.where.not(person_id: nil).select(:person_id))
         .where.not(person_id: exclude.to_a)
         .includes(person: :default_alias)
  end

  # overrides and history rows for every person whose name matches; a name
  # shared by several people is flagged for the reviewer
  def named(percona, exclude)
    by_name = Hash.new { |h, k| h[k] = {} }
    aliases(exclude).find_each do |a|
      [ a.name, a.person.display_name ].compact.each { |n| by_name[norm_name(n, percona.aliases)][a.person.id] = a.person }
    end
    (percona.overrides.keys | percona.history.keys).each do |name|
      people = by_name[name]
      next if people.empty?

      note = people.size > 1 ? "name matches #{people.size} people" : nil
      changes = percona.history.fetch(name, []).sort_by(&:first)
      people.each_value do |person|
        if (current = percona.overrides[name])
          yield person, current, nil, (changes.first && changes.first.first - 1), note
        end
        changes.each_with_index do |(since, company), i|
          yield person, company, since, (changes[i + 1] && changes[i + 1].first - 1), note
        end
      end
    end
  end

  def company_for_email(domains, email)
    parts = email.to_s.downcase.split("@").last.to_s.split(".")
    (0...[ parts.size - 1, 1 ].max).each do |i|
      company = domains[parts[i..].join(".")]
      return company if company
    end
    nil
  end

  def canonical(company)
    name = company.to_s.gsub(/\s*\(.*?\)/, "").strip
    loop do
      stripped = name.sub(COMPANY_SUFFIX, "").strip
      break if stripped == name || stripped.empty?

      name = stripped
    end
    COMPANY_ALIASES.fetch(name.downcase, name)
  end

  # percona_activity.py's _norm_name
  def norm_name(name, aliases = {})
    n = name.to_s.gsub(/\(.*?\)/, "")
    n = n.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase.tr(".", " ").delete("'")
    n = n.squeeze(" ").strip
    aliases.fetch(n, n)
  end

  def add(out, person, company, source, since: nil, till: nil, note: nil)
    key = [ person.id, company, since ]
    return if out.key?(key)

    out[key] = [ person.id, person.display_name, person.default_alias&.email, company, since, till, source, note ]
  end

  # the four dicts, read off the python source line by line
  def read_percona(path)
    text = File.read(path)
    dict = lambda do |name|
      block = text[/^#{name}\b[^\n]*\{\n(.*?)^\}/m, 1] or raise ArgumentError, "#{name} not found in #{path}"
      block.lines.map { |l| l.sub(/\s#.*\z/, "").strip }.reject(&:empty?)
    end
    pairs = ->(name) { dict.call(name).filter_map { |l| l.match(/\A"([^"]+)"\s*:\s*"([^"]+)"/)&.captures }.to_h }
    history = dict.call("COMPANY_NAME_HISTORY").filter_map do |l|
      name = l[/\A"([^"]+)"\s*:/, 1] or next
      [ name, l.scan(/\("(\d{4}-\d{2}-\d{2})",\s*"([^"]+)"\)/).map { |d, c| [ Date.iso8601(d), c ] } ]
    end.to_h
    Percona.new(domains: pairs.call("COMPANY_DOMAINS").transform_keys(&:downcase), overrides: pairs.call("COMPANY_NAME_OVERRIDES"),
                history: history, aliases: pairs.call("NAME_ALIASES"))
  end

  def write(path, domains_path = nil, exclude_path = nil, percona_path: nil)
    percona = percona_path && read_percona(percona_path)
    domains = percona ? percona.domains.dup : {}
    domains.merge!(YAML.safe_load_file(domains_path).to_h { |k, v| [ k.to_s.strip.downcase, v.to_s.strip ] }.reject { |_, v| v.empty? }) if domains_path
    exclude = exclude_path ? File.readlines(exclude_path).map(&:strip).reject(&:empty?).map(&:to_i).to_set : Set.new
    list = rows(domains, exclude, percona: percona)
    CSV.open(path, "w") do |csv|
      csv << HEADER
      list.each { |row| csv << row }
    end
    list.size
  end
end

if $PROGRAM_NAME == __FILE__
  out = ARGV.first
  opts = ARGV.drop(1).each_slice(2).to_h
  abort("usage: generate.rb OUT.csv [--domains DOMAINS.yml] [--percona percona_activity.py] [--exclude EXCLUDE.txt]") unless out && (opts["--domains"] || opts["--percona"])
  puts "#{AffiliationGenerate.write(out, opts['--domains'], opts['--exclude'], percona_path: opts['--percona'])} rows written to #{out}"
end
