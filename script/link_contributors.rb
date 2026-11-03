#!/usr/bin/env ruby
# frozen_string_literal: true

# Link PostgreSQL contributors to people/aliases.
#
# This script fetches contributor lists from the PostgreSQL website and
# assigns contributor memberships to matching people in the database.
#
# PREREQUISITE: The database must already be populated with message data from mbox imports.
#
# Sources:
#   https://www.postgresql.org/developer/committers/
#   https://www.postgresql.org/community/contributors/
#
# Usage:
#   ruby script/link_contributors.rb

require_relative '../config/environment'
require 'net/http'
require 'nokogiri'
require 'uri'

puts "Linking PostgreSQL contributors to people..."

ContributorMembership.delete_all

def normalize_whitespace(text)
  text.to_s.gsub(/\s+/, ' ').strip
end

def fetch_doc(url)
  uri = URI(url)
  response = Net::HTTP.get_response(uri)
  raise "Failed to fetch #{url}: #{response.code} #{response.message}" unless response.is_a?(Net::HTTPSuccess)

  Nokogiri::HTML(response.body)
end

# Never merges people. A contributor's name also sits on list addresses
# (pgsql-hackers@ carried Bruce Momjian and Greg Stark alike), so merging by
# name glued unrelated people together. Duplicates are merged separately,
# see script/person_duplicates_report.rb.
def resolve_person_for(name, email: nil)
  if email.present?
    person = Person.find_by_email(email.sub(/\s+at\s+/, "@"))
    return [ person, person.aliases.to_a ] if person
  end

  aliases = Alias.where("LOWER(name) = ?", name.downcase).includes(:person).to_a
  people = aliases.map(&:person).compact.uniq
  return [ people.first, aliases ] if people.size <= 1

  own = people.select do |person|
    PersonNameMatch.compatible?(PersonNameMatch.norm(person.display_name), PersonNameMatch.norm(name))
  end
  if own.empty?
    puts "  ⚠ #{name}: only on others' addresses (#{people.map(&:id).join(', ')}), skipping"
    return [ nil, aliases ]
  end

  with_users = own.select { |person| person.user.present? }
  if with_users.size > 1
    puts "  ⚠ #{name}: multiple user-owned people (#{with_users.map(&:id).join(', ')}), skipping"
    return [ nil, aliases ]
  end

  target = with_users.first || own.max_by { |person| Alias.where(person_id: person.id).sum(:sender_count) }
  puts "  ⚠ #{name}: #{own.size} people, linking #{target.id}, merge the rest by hand" if own.size > 1
  [ target, aliases ]
end

def add_membership(person, contributor_type, name:, email: nil, company: nil, description: nil)
  membership =
    if person
      ContributorMembership.find_by(person: person, contributor_type: contributor_type) ||
        ContributorMembership.find_by(person_id: nil, contributor_type: contributor_type, name: name)&.tap do |record|
          record.person = person
        end ||
        ContributorMembership.new(person: person, contributor_type: contributor_type)
    else
      ContributorMembership.find_or_initialize_by(person_id: nil, contributor_type: contributor_type, name: name)
    end

  membership.name ||= name
  membership.email ||= email.presence
  membership.company ||= company.presence
  membership.description ||= description.presence

  if membership.new_record?
    membership.save!
    :created
  elsif membership.changed?
    membership.save!
    :updated
  else
    :existing
  end
end

def parse_committers(doc)
  heading = doc.css('h2, h3').find { |node| normalize_whitespace(node.text) == 'Committers' }
  list = if heading
           heading.xpath('following-sibling::*').find { |node| node.name == 'ul' }
  end
  list ||= doc.css('ul').find { |node| node['class'].to_s.include?('committers') }

  return [] unless list

  list.css('li').map { |li| normalize_whitespace(li.text) }.reject(&:empty?)
end

def parse_contributor_cell(cell)
  lines = cell.text.lines.map { |line| normalize_whitespace(line) }.reject(&:empty?)
  first_line = lines.first.to_s
  name = first_line
  email = nil
  if first_line =~ /\A(.+?)\s*\(([^)]+)\)\z/
    name = normalize_whitespace(Regexp.last_match(1))
    email = normalize_whitespace(Regexp.last_match(2))
  end
  company = cell.css('a').first&.text&.strip

  [ name, email, company ]
end

def parse_contributor_sections(doc)
  sections = {
    'Core Team' => :core_team,
    'Major Contributors' => :major_contributor,
    'Significant Contributors' => :significant_contributor,
    'Past Major Contributors' => :past_major_contributor,
    'Past Contributors' => :past_significant_contributor
  }

  result = []
  sections.each do |label, contributor_type|
    heading = doc.css('h2, h3').find { |node| normalize_whitespace(node.text) == label }
    next unless heading

    table = heading.xpath('following-sibling::table[contains(@class, "contributor-table")]').first
    table ||= heading.xpath('following-sibling::table').first
    next unless table

    headers = table.css('th').map { |th| normalize_whitespace(th.text).downcase }
    has_contribution_column = headers.include?('contribution')

    if has_contribution_column
      table.css('tr').each do |row|
        cols = row.css('td')
        next if cols.empty?

        name, email, company = parse_contributor_cell(cols[0])
        next if name.empty?

        description = normalize_whitespace(cols[1]&.text)
        result << {
          name: name,
          email: email,
          company: company,
          contributor_type: contributor_type,
          description: description.presence
        }
      end
    else
      table.css('td').each do |cell|
        name, email, company = parse_contributor_cell(cell)
        next if name.empty?

        result << {
          name: name,
          email: email,
          company: company,
          contributor_type: contributor_type,
          description: nil
        }
      end
    end
  end

  result
end

committers_url = "https://www.postgresql.org/developer/committers/"
contributors_url = "https://www.postgresql.org/community/contributors/"

committers_doc = fetch_doc(committers_url)
contributors_doc = fetch_doc(contributors_url)

total_created = 0
total_updated = 0
total_existing = 0

puts "Parsing committers..."
parse_committers(committers_doc).each do |name|
  person, aliases = resolve_person_for(name)
  result = add_membership(person, :committer, name: name)
  case result
  when :created
    total_created += 1
  when :updated
    total_updated += 1
  when :existing
    total_existing += 1
  end
  if aliases.any?
    puts "  ✓ #{name}: #{aliases.map(&:email).uniq.join(', ')}"
  else
    puts "  ✓ #{name}: no aliases found"
  end
end

puts "Parsing contributors..."
parse_contributor_sections(contributors_doc).each do |entry|
  name = entry[:name]
  person, aliases = resolve_person_for(name, email: entry[:email])
  result = add_membership(
    person,
    entry[:contributor_type],
    name: name,
    email: entry[:email],
    company: entry[:company],
    description: entry[:description]
  )
  case result
  when :created
    total_created += 1
  when :updated
    total_updated += 1
  when :existing
    total_existing += 1
  end

  detail = entry[:description].presence ? " (#{entry[:description]})" : ""
  if aliases.any?
    puts "  ✓ #{name}: #{aliases.map(&:email).uniq.join(', ')}#{detail}"
  else
    puts "  ✓ #{name}: no aliases found#{detail}"
  end
end

puts "\nContributor memberships:"
puts "  created: #{total_created}"
puts "  updated: #{total_updated}"
puts "  existing: #{total_existing}"
