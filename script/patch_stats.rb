#!/usr/bin/env ruby
require_relative "../config/environment"

puts "Patch File Statistics"
puts "===================="
puts "Total patch files: #{PatchFile.count}"
puts "Total attachments with patches: #{Attachment.joins(:patch_files).distinct.count}"
puts ""

puts "Top modified files:"
PatchFile.group(:filename)
         .order(Arel.sql('COUNT(*) DESC'))
         .limit(10)
         .count
         .each { |file, count| puts "  #{file}: #{count} times" }
puts ""

puts "Top contrib modules:"
PatchFile.contrib_files
         .group("SPLIT_PART(filename, '/', 2)")
         .order(Arel.sql('COUNT(*) DESC'))
         .limit(10)
         .count
         .each { |module_name, count| puts "  #{module_name}: #{count} files" }
puts ""

puts "Backend areas:"
PatchFile.backend_files
         .group("SPLIT_PART(filename, '/', 3)")
         .order(Arel.sql('COUNT(*) DESC'))
         .limit(10)
         .count
         .each { |area, count| puts "  #{area}: #{count} files" }
