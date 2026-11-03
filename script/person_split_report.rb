#!/usr/bin/env ruby
# frozen_string_literal: true

# Read-only. Finds persons that hold several different people, mostly left
# over from name-based merges that pulled in a mailing list address carrying
# everybody's name. Per person, each address is:
#
#   shared    used under several unrelated names, none dominant (a list)
#   personal  one dominant name; addresses with compatible names group
#   unknown   only "Noname" or mailbox-like names, stays with the kept group
#
# A person is reported when it has two personal groups, or a shared address
# next to personal ones. Writes <dir>/person_splits.csv: one "keep" row and
# one "split" row per group to move out. Review, delete rows to skip, then
# run script/person_split_apply.rb.
#
#   ruby script/person_split_report.rb [dir]   # default tmp/

require_relative "../config/environment"
require "csv"

module PersonSplitReport
  extend PersonNameMatch

  SHARED_MIN_NAMES = 3
  SHARED_MAX_TOP_SHARE = 0.6

  module_function

  # [[name, weight]] clusters of compatible names, heaviest first
  def name_clusters(rows, locals)
    weights = Hash.new(0)
    rows.each do |_, name, _, sent|
      n = norm(name)
      weights[n] += sent + 1 unless junk_name?(n, locals)
    end

    clusters = []
    weights.sort_by { |_, w| -w }.each do |name, weight|
      cluster = clusters.find { |c| compatible?(c[0], name) || compatible?(name, c[0]) }
      cluster ? cluster[1] += weight : clusters << [ name, weight ]
    end
    clusters.sort_by { |_, w| -w }
  end

  def plan_for(rows, memberships, users)
    by_email = rows.group_by { |r| r[2].downcase.strip }
    return nil if by_email.size < 2

    shared = []
    personal = []
    unknown = []
    by_email.each do |email, email_rows|
      clusters = name_clusters(email_rows, [ email.split("@").first ])
      total = clusters.sum(&:last)
      info = { emails: [ email ], sent: email_rows.sum { |r| r[3] }, aliases: email_rows.size,
               user: email_rows.any? { |r| users.include?(r[4]) }, name: clusters.first&.first }
      if clusters.size >= SHARED_MIN_NAMES && clusters.first[1] < SHARED_MAX_TOP_SHARE * total
        shared << info.merge(shared: true, name: "#{clusters.size} names")
      elsif clusters.empty?
        unknown << info
      else
        personal << info
      end
    end

    groups = []
    personal.sort_by { |i| -i[:sent] }.each do |info|
      group = groups.find { |g| compatible?(g[:name], info[:name]) || compatible?(info[:name], g[:name]) }
      if group
        group[:emails] += info[:emails]
        group[:sent] += info[:sent]
        group[:aliases] += info[:aliases]
        group[:user] ||= info[:user]
      else
        groups << info.dup
      end
    end
    return nil if groups.size < 2 && (shared.empty? || groups.empty?)

    keep = groups.find { |g| g[:user] } || groups.max_by { |g| g[:sent] } || shared.first
    unknown.each do |info|
      keep[:emails] += info[:emails]
      keep[:sent] += info[:sent]
      keep[:aliases] += info[:aliases]
    end

    moved = (groups + shared) - [ keep ]
    memberships.each do |id, name, email|
      email = email.to_s.sub(" at ", "@").downcase.strip
      target = moved.find { |g| g[:emails].include?(email) } ||
               (email.empty? && moved.find { |g| g[:name] && compatible?(norm(name), g[:name]) })
      (target[:membership_ids] ||= []) << id if target
    end

    [ keep.merge(action: "keep") ] + moved.map { |g| g.merge(action: "split") }
  end

  def run(dir)
    users = Alias.where.not(user_id: nil).distinct.pluck(:user_id).to_set
    memberships = ContributorMembership.where.not(person_id: nil)
                                       .pluck(:person_id, :id, :name, :email).group_by(&:first)
    by_person = Alias.pluck(:person_id, :name, :email, :sender_count, :user_id).group_by(&:first)

    plans = by_person.filter_map do |pid, rows|
      plan = plan_for(rows, (memberships[pid] || []).map { |m| m.drop(1) }, users)
      [ pid, plan ] if plan
    end

    FileUtils.mkdir_p(dir)
    path = File.join(dir, "person_splits.csv")
    CSV.open(path, "w") do |csv|
      csv << %w[person action name shared emails sent_messages aliases membership_ids]
      plans.sort_by { |_, plan| -plan.sum { |g| g[:sent] } }.each do |pid, plan|
        plan.each do |g|
          csv << [ pid, g[:action], g[:name], g[:shared] ? "yes" : "", g[:emails].join(" "),
                   g[:sent], g[:aliases], (g[:membership_ids] || []).join(" ") ]
        end
      end
    end

    splits = plans.sum { |_, plan| plan.count { |g| g[:action] == "split" } }
    shared = plans.sum { |_, plan| plan.count { |g| g[:shared] && g[:action] == "split" } }
    puts "persons to split: #{plans.size}, groups to move out: #{splits} (#{shared} shared addresses)"
    puts "wrote #{path}"
  end
end

PersonSplitReport.run(ARGV[0] || Rails.root.join("tmp").to_s) if $PROGRAM_NAME == __FILE__
