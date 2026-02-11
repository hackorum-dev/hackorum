require_relative "../config/environment"
require_relative "../app/services/email_ingestor"
require_relative "../lib/import_options"

options = ImportOptions.parse!

def create_users(fields, created_at, limit = 0)
  return [] unless fields

  # Some old mboxes have header fields without parsed addresses
  addresses = nil
  begin
    addresses = fields.addresses
  rescue NoMethodError
    field_name = (fields.respond_to?(:name) ? fields.name : 'unknown')
    puts "WARN: #{field_name} has no addresses; skipping"
    return []
  end

  users = []
  count = 0
  addresses.each_index do |idx|
    break if count > limit
    count = count + 1

    display_names = fields.respond_to?(:display_names) ? (fields.display_names || []) : []
    name_or_alias = display_names[idx]
    name_or_alias = "Noname" if name_or_alias == nil or name_or_alias.empty?
    email = addresses[idx]
    next if email.nil? || email.empty?
    u = Alias.find_by(email: email, name: name_or_alias)
    unless u
      u = Alias.create! email: email, name: name_or_alias, created_at: created_at
    end

    users << u
  end

  users
end

def lookup_main_part(parts, concat = false)
  body = ''
  parts.each do |p|
    if p.parts.size > 0
      body += lookup_main_part p.parts
      return body if !body.empty? and !concat
    end
    next unless p.content_type
    if p.content_type.match(/text\/plain/)
      return p.decoded unless concat
      body += p.decoded
    end
  end
  body
end

def clean_reference(ref)
  return ref[/.*<([^>]*)/, 1] if ref[0] == '<'
  ref
end

def add_mentions(msg, users)
  users.each do |usr|
    next if usr.email.end_with? 'postgresql.org'
    Mention.create! message: msg, alias: usr
  end
end

def sanitize_email_date(mail_date, mail_date_header, message_id)
  # Sanity check: detect and handle misparsed dates from old emails
  # PostgreSQL mailing list started in 1996, so anything before that or in the future is wrong
  current_time = Time.now

  return mail_date if mail_date.nil? || (mail_date >= Time.parse('1996-01-01') && mail_date <= current_time)

  original_date = mail_date
  sanitized_date = mail_date

  # Try to extract year from the Date header string if available
  # This handles 2-digit year issues in old emails
  if mail_date_header && mail_date_header.to_s =~ /\b(\d{2})\s+\w+\s+(\d{2,4})\b/
    year_match = mail_date_header.to_s.match(/\b\d{1,2}\s+\w+\s+(\d{2,4})\b/)
    if year_match
      year = year_match[1].to_i
      # Convert 2-digit years: 96-99 -> 1996-1999, 00-95 -> 2000-2095 (but cap at current year)
      if year < 100
        year = year >= 96 ? 1900 + year : 2000 + year
      end
      # Reconstruct the date with the corrected year
      begin
        sanitized_date = Time.new(year, mail_date.month, mail_date.day, mail_date.hour, mail_date.min, mail_date.sec, mail_date.utc_offset)
      rescue ArgumentError
        # If reconstruction fails, fall through to default handling
      end
    end
  end

  # Final sanity check: still invalid? Use a reasonable default
  if sanitized_date > current_time || sanitized_date.year < 1996
    puts "WARN #{message_id}: Invalid date #{original_date} (parsed as #{sanitized_date}), using fallback date"
    # Use epoch time from the message filename/position or just a default old date
    sanitized_date = Time.parse('2000-01-01 00:00:00 UTC')
  end

  sanitized_date
end

def parse_message(message, update_existing:)
  msg = EmailIngestor.new.ingest_raw(message, fallback_threading: true, update_existing: update_existing)
  puts "Processing #{msg&.message_id || '(duplicate or invalid)'}"
end

update_existing = options[:update_existing]
message = ""

ARGV.each do |fn|
  puts "Processing #{fn}..."
  File.open(fn, "r") do |f|
    f.each_line do |line|
      # Some old lines contain illegal characters
      line = line.encode("utf-8", invalid: :replace)

      # all new messages refer to lists.postgresql.org, but not old emails
      # And we can't simply check for From, as it also matches inline attachments containing git diffs
      if line.match(/^From [^@]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+/i)
        parse_message(message, update_existing: update_existing) unless message.empty?
        message = ""
      else
        message << line
      end
    end
  end
end
