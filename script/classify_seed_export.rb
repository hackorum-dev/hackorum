usage = "usage: classify_seed_export.rb OUT.jsonl [--since TAG]"
args = ARGV.dup
since_tag = nil
if (i = args.index("--since"))
  since_tag = args[i + 1] or abort usage
  args.slice!(i, 2)
end
path = args.shift or abort usage
abort usage if args.any?

since = since_tag && ReleaseTag.find_by!(name: since_tag).released_at
n = 0
File.open(path, "w") do |f|
  Classify::SeedExport.rows(since: since).each do |row|
    f.puts(row.to_json)
    n += 1
  end
end
puts "wrote #{n} rows to #{path}"
