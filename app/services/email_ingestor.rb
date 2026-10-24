# frozen_string_literal: true

class EmailIngestor
  def ingest_raw(raw_message, mailing_list:, fallback_threading: false, trust_date: false, update_existing: [])
    m = Mail.new(raw_message)

    message_id = clean_reference(m.message_id)
    message_id = nil if message_id.blank?
    unless message_id
      Rails.logger.warn("EmailIngestor: skipping mail without Message-ID (subject: #{m.subject.inspect})")
      return nil
    end
    # an unparseable Date: comes back as a String even when trusted
    sent_at = trust_date && m.date.respond_to?(:utc) ? m.date : sanitize_email_date(m.date, m[:date], message_id)

    body = normalize_body(extract_body(m))
    reply_to_message_id = m.in_reply_to ? clean_reference(m.in_reply_to) : nil

    existing_message = Message.find_by_message_id(message_id)
    if existing_message
      update_existing_message(existing_message, body: body, sent_at: sent_at,
                              reply_to_message_id: reply_to_message_id, update_existing: update_existing)
      associate_mailing_list(existing_message, mailing_list)
      return existing_message
    end

    pending_echo = find_pending_echo(
      reply_to_message_id: reply_to_message_id,
      from_addresses: extract_from_emails(m),
      echo_body: body,
      echo_sent_at: sent_at
    )
    if pending_echo
      pending_echo.update_columns(message_id: message_id) if pending_echo.message_id != message_id
      update_existing_message(pending_echo, body: body, sent_at: sent_at,
                              reply_to_message_id: reply_to_message_id, update_existing: update_existing)
      associate_mailing_list(pending_echo, mailing_list)
      return pending_echo
    end

    import_log = ""

    from = build_from_aliases(m, sent_at)
    to = create_users(m[:to], sent_at)
    cc = create_users(m[:cc], sent_at)

    subject = (m.subject || "No title").delete("\0")

    reply_to_msg, import_log = resolve_threading(m, reply_to_message_id, import_log)
    if fallback_threading && reply_to_msg.nil? && subject.present? && subject.match?(/\A\s*(re|aw|fwd):/i)
      reply_to_msg = fallback_thread_lookup(subject, message_id: message_id, references: m.references, sent_at: sent_at, mailing_list: mailing_list)
      import_log = [ import_log, "Resolved by subject fallback" ].reject(&:blank?).join(" | ") if reply_to_msg
    end

    topic = reply_to_msg ? reply_to_msg.topic : Topic.create!(
      creator: from[0],
      creator_person_id: from[0].person_id,
      title: subject,
      created_at: sent_at
    )
    import_log = nil if import_log == ""

    begin
      # savepoint: callers may hold an outer transaction, which a failed
      # insert would otherwise abort before the rescue can look up the winner
      msg = Message.transaction(requires_new: true) do
        Message.create!(
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
      end
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      raise unless message_id && (e.is_a?(ActiveRecord::RecordNotUnique) || e.message.include?("Message has already been taken"))
      existing_message = Message.find_by(message_id: message_id)
      raise unless existing_message
      associate_mailing_list(existing_message, mailing_list)
      return existing_message
    end

    associate_mailing_list(msg, mailing_list)

    update_default_alias_for_person(msg.sender)

    add_mentions(msg, (to + cc).uniq(&:id))

    handle_attachments(m, msg)
    # attachment callbacks already recompute; only needed for inline-only diffs
    msg.recompute_patch_paths! if msg.attachments.none?

    MessageActivityBuilder.new(msg).process!

    msg
  end

  private

  def associate_mailing_list(message, mailing_list)
    MessageMailingList.find_or_create_by!(message: message, mailing_list: mailing_list)
  end

  def update_existing_message(message, body:, sent_at:, reply_to_message_id:, update_existing:)
    return if update_existing.empty? && message.state != Message::STATE_PENDING

    updates = {}
    updates[:body] = body if update_existing.include?(:body) && message.body != body

    date_changed = update_existing.include?(:date) && sent_at && message.created_at != sent_at

    if date_changed
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

    # Echo of an outgoing pending message has arrived from the list.
    # Counters fired at draft-send time, so just flip the state.
    flipped_to_sent = false
    if message.state == Message::STATE_PENDING
      updates[:state]   = Message::STATE_SENT
      updates[:sent_at] = message.sent_at
      flipped_to_sent = true
    end

    message.update_columns(updates) if updates.any?
    message.recompute_patch_paths! if updates.key?(:body)
    resync_activity_after_date_change(message) if date_changed

    if flipped_to_sent
      pending_age = message.sent_at ? (Time.current - message.sent_at).to_i : nil
      ActiveSupport::Notifications.instrument("outgoing.echo.matched",
        message_id: message.message_id,
        pending_age_seconds: pending_age)
    end
  end

  # created_at carries the mail Date:, so correcting it moves the message within
  # the thread. The counter callbacks only run on create/destroy, so the cached
  # latest-activity timestamps have to be recomputed here.
  def resync_activity_after_date_change(message)
    topic = message.topic
    return unless topic

    topic.resync_last_message!

    participant = TopicParticipant.find_by(topic_id: topic.id, person_id: message.sender_person_id)
    return unless participant

    stats = topic.messages.where(sender_person_id: message.sender_person_id)
                 .pick(Arel.sql("MIN(created_at), MAX(created_at)"))
    return unless stats

    participant.update_columns(first_message_at: stats[0], last_message_at: stats[1])
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

      Attachment.create!(
        message: msg,
        file_name: a.filename&.delete("\0"),
        content_type: a[:content_type].decoded,
        body: Base64.encode64(a.decoded)
      )
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
      # nearest ancestor first
      references.reverse_each do |ref|
        reply_to_msg = Message.find_by_message_id(clean_reference(ref))
        break if reply_to_msg
        import_log += "Reference msg id not found: #{clean_reference(ref)}" unless reply_to_msg
      end
    end

    [ reply_to_msg, import_log ]
  end

  def extract_body(m)
    body = nil
    if m.parts.size.positive?
      body = lookup_main_part(m.parts).presence || html_part_text(m.parts)
    else
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

  def html_part_text(parts)
    parts.each do |p|
      if p.parts.size > 0
        text = html_part_text(p.parts)
        return text if text
      elsif p.content_type&.match?(/text\/html/) && !p.attachment?
        return Nokogiri::HTML(p.decoded).text.strip.presence
      end
    end
    nil
  end

  def create_users(fields, created_at, limit = nil)
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
      break if limit && count >= limit
      count += 1
      display_names = fields.respond_to?(:display_names) ? (fields.display_names || []) : []
      name_or_alias = display_names[idx]
      name_or_alias = name_or_alias.to_s.delete("\0").strip
      name_or_alias = "Noname" if name_or_alias.blank?
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

  # Gmail rewrites Message-IDs on send, so the echo from the list has a different
  # id than the pending row we created. Match heuristically on parent reference,
  # sender, body fragment, and time window.
  PENDING_ECHO_WINDOW = 24.hours
  PENDING_ECHO_MIN_BODY = 20

  def find_pending_echo(reply_to_message_id:, from_addresses:, echo_body:, echo_sent_at:)
    return nil if from_addresses.empty?

    scope = Message.pending
    scope = scope.where(reply_to_message_id: reply_to_message_id) if reply_to_message_id.present?

    reference_time = echo_sent_at || Time.current
    scope = scope.where(sent_at: (reference_time - PENDING_ECHO_WINDOW)..(reference_time + PENDING_ECHO_WINDOW))

    sender_alias_ids = Alias.where("LOWER(email) IN (?)", from_addresses).pluck(:id)
    return nil if sender_alias_ids.empty?
    scope = scope.where(sender_id: sender_alias_ids)

    candidates = scope.to_a
    return nil if candidates.empty?

    echo_normalized = normalize_for_body_match(echo_body)
    return nil if echo_normalized.blank?

    matches = candidates.select do |c|
      pending_normalized = normalize_for_body_match(c.body)
      next false if pending_normalized.length < PENDING_ECHO_MIN_BODY
      echo_normalized.include?(pending_normalized)
    end

    matches.size == 1 ? matches.first : nil
  end

  def normalize_for_body_match(text)
    text.to_s.gsub(/\s+/, " ").strip
  end

  def extract_from_emails(mail)
    addrs = mail.from
    return [] unless addrs
    addrs = [ addrs ] if addrs.is_a?(String)
    addrs.compact.map { |a| a.to_s.downcase.strip }.reject(&:blank?)
  rescue NoMethodError
    []
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

  def fallback_thread_lookup(subject, message_id:, references:, sent_at:, mailing_list: nil)
    normalized_subject = subject.to_s.strip
    return nil if normalized_subject.blank?

    reference_time = sent_at || Time.current
    window_start = reference_time - 30.days
    window_end = reference_time + 1.day

    target_variant = normalize_subject_for_threading(normalized_subject)

    candidates = Message.where(created_at: window_start..window_end)
    if mailing_list
      candidates = candidates.joins(:message_mailing_lists)
                             .where(message_mailing_lists: { mailing_list_id: mailing_list.id })
    end
    candidates = candidates.order(created_at: :desc).limit(300).to_a

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

    unless mail_date.respond_to?(:utc)
      begin
        mail_date = Time.parse(mail_date.to_s)
      rescue ArgumentError, TypeError
        return Time.parse("2000-01-01 00:00:00 UTC")
      end
    end

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
