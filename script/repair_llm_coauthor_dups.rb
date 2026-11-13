#!/usr/bin/env ruby
# frozen_string_literal: true

# One-off: drop llm author rows on commits that already have a parsed
# co-author. The ingestor only checked for a parsed author row before.
#
# Prints what it would do and writes nothing unless --commit is given.
require_relative "../config/environment"

rows = CommitPerson.llm.where(role: "author")
                   .where("EXISTS (SELECT 1 FROM commit_people p WHERE p.commit_id = commit_people.commit_id AND p.source = 'parsed' AND p.role = 'co_author')")

puts "llm author rows to delete: #{rows.count}"

unless ARGV.include?("--commit")
  puts "dry run, nothing written - pass --commit to apply"
  exit
end

puts "deleted #{rows.delete_all}"
