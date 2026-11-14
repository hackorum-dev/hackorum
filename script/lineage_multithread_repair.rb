# usage: bin/rails runner script/lineage_multithread_repair.rb [--apply]
repair = Lineage::MultithreadRepair.new
plan = repair.plan
puts "commits #{plan[:commits]}, topics #{plan[:topics]}, est input tokens #{plan[:est_input_tokens]}"
plan[:pairs].sort_by { |_, n| -n }.each { |pair, n| puts format("%6d  %s", n, pair) }
if ARGV.include?("--apply")
  puts "rechecks opened: #{repair.apply!}"
else
  puts "dry run; pass --apply to open rechecks"
end
