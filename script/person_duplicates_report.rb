#!/usr/bin/env ruby
# frozen_string_literal: true

# Read-only. Finds names credited in commit trailers that map to more than
# one person, and sorts the extra persons into:
#
#   trivial   same name, no foreign alias names, and some evidence (shared
#             mailbox or domain, name in the mailbox, own commit credits)
#   probable  same name, no foreign alias names, no evidence
#   review    carries alias names of somebody else (shared/list address)
#   stray     a different person that has one alias mislabelled with this
#             name; not a duplicate, never merge
#
# Writes <dir>/person_merges.csv (trivial + probable, one row per merge) and
# <dir>/person_candidates.csv (every candidate of every such name).
#
#   ruby script/person_duplicates_report.rb [dir]   # default tmp/

require_relative "../config/environment"
require "csv"

module PersonDuplicatesReport
  FREEMAIL = %w[
    gmail.com googlemail.com yahoo.com yahoo.co.in hotmail.com outlook.com live.com aol.com
    qq.com 163.com 126.com sina.com sina.cn foxmail.com mail.ru yandex.ru ya.ru bk.ru
    gmx.de gmx.net web.de icloud.com me.com protonmail.com proton.me free.fr
  ].to_set

  extend PersonNameMatch

  module_function

  def run(dir)
    credited = CommitPerson.where.not(raw_name: [ nil, "" ]).distinct.pluck(:raw_name)
                           .map { |n| norm(n) }.uniq
                           .select { |n| tokens(n).size >= 2 && !n.include?("@") }
    credits = CommitPerson.where.not(person_id: nil).where.not(raw_email: nil).group(:person_id).count
    users = User.where(deleted_at: nil).where.not(person_id: nil).pluck(:person_id).to_set
    default_alias = Person.where.not(default_alias_id: nil).pluck(:id, :default_alias_id).to_h
    by_person = Alias.pluck(:person_id, :name, :email, :sender_count, :id).group_by(&:first)
    by_name = Hash.new { |h, k| h[k] = Set.new }
    by_person.each { |pid, rows| rows.each { |_, n, _, _, _| by_name[norm(n)] << pid } }

    merges = []
    merged_sources = Set.new
    candidates = []
    stats = Hash.new(0)

    credited.each do |name|
      pids = by_name[name]
      next if pids.size < 2

      infos = pids.map do |pid|
        rows = by_person[pid]
        emails = rows.map { |r| r[2].downcase.strip }.uniq
        locals = emails.map { |e| e.split("@").first }
        named = rows.reject { |r| junk_name?(norm(r[1]), locals) }
        best = named.find { |r| r[4] == default_alias[pid] } || named.max_by { |r| r[3] }
        primary_name = best ? norm(best[1]) : name
        others = rows.map { |r| norm(r[1]) }.uniq
                     .reject { |o| compatible?(o, name) || junk_name?(o, locals) }
        { pid: pid, emails: emails, locals: locals, primary: primary_name, others: others,
          credits: credits[pid] || 0, msgs: rows.sum { |r| r[3] }, user: users.include?(pid) }
      end

      same, stray = infos.partition { |i| compatible?(i[:primary], name) || compatible?(name, i[:primary]) }
      stray.each { |i| i[:tier] = "stray" }
      next if same.size < 2 && stray.empty?

      same.sort_by! { |i| [ i[:user] ? 0 : 1, -i[:credits], -i[:msgs] ] }
      main = same.first
      main[:tier] = "main" if main
      main_locals = main ? main[:locals].to_set : Set.new
      main_domains = main ? main[:emails].map { |e| e.split("@").last }.reject { |d| FREEMAIL.include?(d) }.to_set : Set.new
      name_tokens = tokens(name)

      same.drop(1).each do |s|
        evidence = []
        evidence << "same mailbox" if s[:locals].any? { |l| main_locals.include?(l) && !name_tokens.include?(l) }
        evidence << "same domain" if s[:emails].any? { |e| main_domains.include?(e.split("@").last) }
        evidence << "name in mailbox" if s[:locals].any? { |l| name_in_mailbox?(l, name_tokens) }
        evidence << "own commit credits" if s[:credits].positive?
        s[:evidence] = evidence
        s[:tier] = if s[:others].any? || (s[:user] && main[:user]) then "review"
        elsif evidence.any? then "trivial"
        else "probable"
        end
        next unless %w[trivial probable].include?(s[:tier])
        # "yura sokolov" and "sokolov yura" list the same person twice
        next unless merged_sources.add?(s[:pid])

        merges << [ s[:tier], name, s[:pid], s[:emails].join(" "), s[:msgs], s[:credits],
                    main[:pid], main[:emails].join(" "), main[:credits], evidence.join("; ") ]
      end

      (same + stray).each do |i|
        stats[i[:tier]] += 1
        candidates << [ name, i[:tier], i[:pid], i[:primary], i[:emails].join(" "), i[:msgs], i[:credits],
                        i[:user] ? "yes" : "", i[:others].first(5).join("; "), (i[:evidence] || []).join("; ") ]
      end
    end

    FileUtils.mkdir_p(dir)
    CSV.open(File.join(dir, "person_merges.csv"), "w") do |csv|
      csv << %w[tier name source_person source_emails source_msgs source_credits
                target_person target_emails target_credits evidence]
      merges.sort_by { |m| [ m[0] == "trivial" ? 0 : 1, m[1] ] }.each { |m| csv << m }
    end
    CSV.open(File.join(dir, "person_candidates.csv"), "w") do |csv|
      csv << %w[name tier person primary_name emails msgs commit_credits has_user foreign_alias_names evidence]
      candidates.each { |c| csv << c }
    end

    puts "names with several persons: #{candidates.map(&:first).uniq.size}"
    stats.sort.each { |tier, n| puts "  #{tier}: #{n}" }
    puts "wrote #{dir}/person_merges.csv, #{dir}/person_candidates.csv"
  end
end

PersonDuplicatesReport.run(ARGV[0] || Rails.root.join("tmp").to_s) if $PROGRAM_NAME == __FILE__
