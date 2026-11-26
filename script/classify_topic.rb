# Classify single topics locally with codex. Writes nothing unless --ingest.
# Usage: bin/rails runner script/classify_topic.rb --topic ID [--topic ID ...] [--model NAME] [--effort LEVEL] [--ingest]

require "optparse"

options = { topics: [], model: Classify::MODEL, effort: Classify::EFFORT, timeout: 600, ingest: false }
OptionParser.new do |o|
  o.banner = "Usage: bin/rails runner script/classify_topic.rb --topic ID [--topic ID ...] [options]"
  o.on("--topic ID", Integer, "topic id, repeatable") { |v| options[:topics] << v }
  o.on("--model NAME", "codex model (default #{Classify::MODEL})") { |v| options[:model] = v }
  o.on("--effort LEVEL", "reasoning effort (default #{Classify::EFFORT})") { |v| options[:effort] = v }
  o.on("--timeout SEC", Integer, "codex timeout (default 600)") { |v| options[:timeout] = v }
  o.on("--ingest", "write the result as a local run and bot note (default: write nothing)") { options[:ingest] = true }
  o.on("--jobs-root PATH", "job dirs (default tmp/classify_local)") { |v| options[:jobs_root] = v }
end.parse!(ARGV)

abort "--topic missing" if options[:topics].empty?

extra = options[:jobs_root] ? { jobs_root: options[:jobs_root] } : {}
options[:topics].each do |id|
  topic = Topic.find_by(id: id)
  unless topic
    puts "#{id} not found"
    next
  end
  out = Classify::LocalRun.call(topic: topic, model: options[:model], effort: options[:effort],
                                timeout: options[:timeout], ingest: options[:ingest], **extra)
  u = out[:usage]
  tokens = "#{u[:input_tokens]}/#{u[:cached_input_tokens]}/#{u[:output_tokens]}"
  secs = format("%.0fs", out[:duration_s])
  if (r = out[:result])
    g = r["group"]
    group = g["id"] ? "##{g['id']}" : (g["new_name"] ? "new:#{g['new_name']}" : "-")
    puts [ id, r["kind"], r["size"] || "-", r["enhancement"].nil? ? "-" : (r["enhancement"] ? "enh" : "new"), r["not_a_bug"], group, r["feature_name"], tokens, secs ].join(" ")
    r["evidence"].each { |e| puts "  #{e}" }
  else
    puts [ id, "FAILED", out[:failure_kind], tokens, secs ].join(" ")
  end
end
