require_relative "../config/environment"
require_relative "../app/services/email_ingestor"
require_relative "../lib/import_options"

options = ImportOptions.parse!

if ARGV.length != 2
  puts "Usage: #{$PROGRAM_NAME} [options] /path/to/mbox <message-id>"
  exit 1
end

mbox_path = ARGV[0]
target_id = MessageIdNormalizer.normalize(ARGV[1])

if target_id.nil? || target_id.empty?
  puts "ERROR: message-id is blank after normalization"
  exit 1
end

def normalize_message_id(message)
  MessageIdNormalizer.normalize(Mail.new(message).message_id)
rescue => e
  warn "WARN: failed to parse message id (#{e.class}: #{e.message})"
  ''
end

def process_message(message, target_id, update_existing:)
  return false if message.empty?

  message_id = normalize_message_id(message)
  return false if message_id.empty?
  return false unless message_id == target_id

  msg = EmailIngestor.new.ingest_raw(message, fallback_threading: true, update_existing: update_existing)
  if msg
    puts "Reimported #{msg.message_id}"
  else
    puts "Message #{target_id} not imported (invalid message id?)"
  end
  true
end

update_existing = options[:update_existing]
found = false
message = ""

puts "Scanning #{mbox_path} for #{target_id}..."

File.open(mbox_path, "r") do |f|
  f.each_line do |line|
    line = line.encode("utf-8", invalid: :replace)

    if line.match(/^From [^@]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+/i)
      if process_message(message, target_id, update_existing: update_existing)
        found = true
        break
      end
      message = ""
    else
      message << line
    end
  end
end

if !found
  found = process_message(message, target_id, update_existing: update_existing)
end

puts "Message not found in #{mbox_path}" unless found
