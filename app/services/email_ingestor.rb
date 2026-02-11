# frozen_string_literal: true

class EmailIngestor
  def ingest_raw(raw_message, fallback_threading: false, trust_date: false, update_existing: [])
    m = Mail.new(raw_message)

    message_id = clean_reference(m.message_id)
    message_id = nil if message_id.blank?
    return nil unless message_id
    sent_at = trust_date ? m.date : sanitize_email_date(m.date, m[:date], message_id)

    body = normalize_body(extract_body(m))
    reply_to_message_id = m.in_reply_to ? clean_reference(m.in_reply_to) : nil

    existing_message = Message.find_by_message_id(message_id)
    if existing_message
      update_existing_message(existing_message, body: body, sent_at: sent_at,
                              reply_to_message_id: reply_to_message_id, update_existing: update_existing)
      return existing_message
    end

    import_log = ""

    from = build_from_aliases(m, sent_at)
    to = create_users(m[:to], sent_at)
    cc = create_users(m[:cc], sent_at)

    subject = m.subject || "No title"

    reply_to_msg, import_log = resolve_threading(m, reply_to_message_id, import_log)
    if fallback_threading && reply_to_msg.nil? && subject.present? && subject.match?(/\A\s*(re|aw|fwd):/i)
      reply_to_msg = fallback_thread_lookup(subject, message_id: message_id, references: m.references, sent_at: sent_at)
      import_log = [ import_log, "Resolved by subject fallback" ].reject(&:blank?).join(" | ") if reply_to_msg
    end

    topic = reply_to_msg ? reply_to_msg.topic : Topic.create!(
      creator: from[0],
      creator_person_id: from[0].person_id,
      title: subject,
      created_at: sent_at
    )
    import_log = nil if import_log == ""

    msg = Message.create!(
      topic: topic,
      sender: from[0],
      sender_person_id: from[0].person_id,
      reply_to: reply_to_msg,
      reply_to_message_id: reply_to_message_id,
      subject: subject,
      body: body,
      created_at: sent_at,
      message_id: message_id,
      import_log: import_log
    )

    update_default_alias_for_person(msg.sender)

    add_mentions(msg, to)
    add_mentions(msg, cc)

    handle_attachments(m, msg)

    MessageActivityBuilder.new(msg).process!

    msg
  end

  private

  def update_existing_message(message, body:, sent_at:, reply_to_message_id:, update_existing:)
    return if update_existing.empty?

    updates = {}
    updates[:body] = body if update_existing.include?(:body)

    if update_existing.include?(:date) && sent_at && message.created_at != sent_at
      updates[:created_at] = sent_at

      # Update topic date if this is the first message
      topic = message.topic
      if topic && topic.messages.order(:created_at).first&.id == message.id
        topic.update_columns(created_at: sent_at)
      end
    end

    if update_existing.include?(:reply_to_message_id) && reply_to_message_id
      updates[:reply_to_message_id] = reply_to_message_id
    end

    message.update_columns(updates) if updates.any?
  end

  def build_from_aliases(m, sent_at)
    if m.from.nil? || m.from[0].nil?
      name = m[:from].to_s.strip
      name = "Unknown User" if name.empty?
      email = "#{name.downcase.gsub(/[^a-z0-9]/, '_')}@unknown.user"
      person = Person.find_or_create_by_email(email)
      [ Alias.find_or_create_by(email: email, name: name) do |a|
        a.created_at = sent_at
        a.person_id = person.id
      end ]
    else
      from = create_users(m[:from], sent_at, 1)
      if from.empty?
        [ Alias.find_or_create_by(email: "unknown@unknown.user", name: "Unknown User") { |a| a.created_at = sent_at } ]
      else
        from
      end
    end
  end

  def handle_attachments(m, msg)
    m.attachments.each do |a|
      next if a[:content_type].nil?
      next if a[:content_type].decoded.match(/^application\/pgp-signature;/)
      next if a[:content_type].decoded.match(/^application\/x-pkcs7-signature/)
      next if a[:content_type].decoded.match(/^text\/x-vcard/)

      attachment = Attachment.create!(
        message: msg,
        file_name: a.filename,
        content_type: a[:content_type].decoded,
        body: Base64.encode64(a.decoded)
      )

      if attachment.patch?
        begin
          PatchParsingService.new(attachment).parse!
        rescue => e
          Rails.logger.warn("Patch parsing error for #{attachment.id}: #{e.message}") if defined?(Rails)
        end
      end
    end
  end

  def resolve_threading(m, reply_to_message_id, import_log)
    reply_to_msg = nil

    if reply_to_message_id
      reply_to_msg = Message.find_by_message_id(reply_to_message_id)
      import_log += "Reply to msg id not found: #{reply_to_message_id}" unless reply_to_msg
    end

    if m.references && reply_to_msg.nil?
      references = m.references
      references = [] unless references
      references = [ references ] if references.is_a?(String)
      references.each do |ref|
        reply_to_msg = Message.find_by_message_id(clean_reference(ref))
        break if reply_to_msg
        import_log += "Reference msg id not found: #{clean_reference(ref)}" unless reply_to_msg
      end
    end

    [ reply_to_msg, import_log ]
  end

  def extract_body(m)
    body = nil
    body = lookup_main_part(m.parts) if m.parts.size.positive?
    unless body
      begin
        body = m.decoded
      rescue => e
        body = "[Message body could not be decoded - encoding: #{m.body.encoding}, error: #{e.message}]"
      end
    end
    normalized = body.to_s.dup
    normalized.encode!("UTF-8", invalid: :replace, undef: :replace, replace: "?")
    normalized
  end

  def normalize_body(body)
    text = body.to_s.dup
    text.delete!("\000")
    text.gsub!("\r\n", "\n")
    text.gsub!("\r", "\n")
    text
  end

  def create_users(fields, created_at, limit = 0)
    return [] unless fields
    addresses = nil
    begin
      addresses = fields.addresses
    rescue NoMethodError
      return []
    end
    users = []
    count = 0
    addresses.each_index do |idx|
      break if count > limit
      count += 1
      display_names = fields.respond_to?(:display_names) ? (fields.display_names || []) : []
      name_or_alias = display_names[idx]
      name_or_alias = "Noname" if name_or_alias.nil? || name_or_alias.empty?
      email = addresses[idx]
      next if email.nil? || email.empty?
      person = Person.find_or_create_by_email(email)
      Person.attach_alias_group!(email, person: person)
      u = Alias.find_by(email: email, name: name_or_alias)
      if u
        u.update_columns(person_id: person.id) if u.person_id.nil?
      else
        u = Alias.create!(email: email, name: name_or_alias, created_at: created_at, person_id: person.id)
      end
      users << u
    end
    users
  end

  def lookup_main_part(parts, concat = false)
    body = ""
    parts.each do |p|
      if p.parts.size > 0
        body += lookup_main_part(p.parts)
        return body if !body.empty? && !concat
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
    MessageIdNormalizer.normalize(ref)
  end

  def update_default_alias_for_person(alias_record)
    return unless alias_record&.person
    person = alias_record.person

    # For persons with users, only fix if current default is Noname
    if person.user.present?
      return unless person.default_alias&.name == "Noname"
      return if alias_record.name == "Noname"
      person.update_columns(default_alias_id: alias_record.id)
      return
    end

    # For persons without users, use best alias by sender_count
    current = person.default_alias

    # If no default yet, set this one
    if current.nil?
      person.update_columns(default_alias_id: alias_record.id)
      return
    end

    # If current is Noname and new one isn't, switch
    if current.name == "Noname" && alias_record.name != "Noname"
      person.update_columns(default_alias_id: alias_record.id)
      return
    end

    # If both are non-Noname, prefer higher sender_count
    # Note: sender_count may not be updated yet (counter_cache happens after commit)
    # So we compare by checking if current has any messages
    if alias_record.name != "Noname" && current.name != "Noname"
      # Keep the one with more messages - current wins ties
      # Since counter isn't updated yet, reload to get accurate count
      current_count = current.sender_count
      # New alias just sent a message, so its effective count is sender_count + 1
      new_effective_count = alias_record.sender_count + 1
      if new_effective_count > current_count
        person.update_columns(default_alias_id: alias_record.id)
      end
    end
  end

  def fallback_thread_lookup(subject, message_id:, references:, sent_at:)
    normalized_subject = subject.to_s.strip
    return nil if normalized_subject.blank?

    reference_time = sent_at || Time.current
    window_start = reference_time - 30.days
    window_end = reference_time + 1.day

    target_variant = normalize_subject_for_threading(normalized_subject)

    candidates = Message.where(created_at: window_start..window_end)
                        .order(created_at: :desc)
                        .limit(300)
                        .to_a

    matched = candidates.select do |msg|
      normalize_subject_for_threading(msg.subject) == target_variant
    end

    return nil if matched.empty?

    target_ids = [ message_id, *(references || []) ].compact.map { |ref| clean_reference(ref) }.reject(&:blank?)
    return matched.first if target_ids.empty?

    matched.find do |msg|
      mid = msg.message_id.to_s
      target_ids.any? { |tid| similarity(mid, tid) >= 0.7 }
    end || matched.first
  end

  def normalize_subject_for_threading(subject)
    s = subject.to_s.downcase.strip
    s = s.gsub(/\[[^\]]+\]\s*/, " ")          # drop list tags like [HACKERS]
    s = s.gsub(/(\s*(re|aw|fwd):\s*)+/i, " ") # drop any re/aw/fwd prefixes wherever they appear
    s = s.gsub(/\(fwd\)/i, " ")               # drop inline fwd markers
    s.squeeze(" ").strip
  end

  def similarity(a, b)
    return 0.0 if a.blank? || b.blank?
    max_len = [ a.length, b.length ].max
    return 1.0 if max_len.zero?
    dist = a.levenshtein_distance(b)
    1.0 - (dist.to_f / max_len)
  rescue NoMethodError
    a == b ? 1.0 : 0.0
  end

  def add_mentions(msg, users)
    users.each do |usr|
      next if usr.email.end_with?("postgresql.org")
      Mention.create!(message: msg, alias: usr, person_id: usr.person_id)
    end
  end

  def sanitize_email_date(mail_date, mail_date_header, message_id)
    return mail_date if mail_date.nil?

    current_time_utc = Time.now.utc
    mail_date_utc = mail_date.utc
    min_valid_date = Time.parse("1996-01-01 00:00:00 UTC")
    future_tolerance = 24 * 3600

    if mail_date_utc >= min_valid_date && mail_date_utc <= current_time_utc + future_tolerance
      return mail_date
    end

    sanitized_date = mail_date

    if mail_date_header && mail_date_header.to_s =~ /\b(\d{2})\s+\w+\s+(\d{2,4})\b/
      year_match = mail_date_header.to_s.match(/\b\d{1,2}\s+\w+\s+(\d{2,4})\b/)
      if year_match
        year = year_match[1].to_i
        year = year >= 96 ? 1900 + year : 2000 + year if year < 100
        begin
          sanitized_date = Time.new(year, mail_date.month, mail_date.day, mail_date.hour, mail_date.min, mail_date.sec, mail_date.utc_offset)
        rescue ArgumentError
        end
      end
    end

    if sanitized_date.utc > current_time_utc + future_tolerance || sanitized_date.year < 1996
      sanitized_date = Time.parse("2000-01-01 00:00:00 UTC")
    end

    sanitized_date
  end
end
