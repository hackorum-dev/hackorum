path = ARGV.fetch(0) { abort "usage: classify_seed_import.rb IN.json" }
puts Classify::SeedImport.call(JSON.parse(File.read(path))).inspect
