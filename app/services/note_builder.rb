class NoteBuilder
  class Error < StandardError; end

  MentionTarget = Struct.new(:name, :record)

  def initialize(author:)
    @author = author
  end

  def create!(topic:, message: nil, body:)
    raise Error, "You must be signed in to add a note" unless author
    body_text = body.to_s.strip
    raise Error, "Note cannot be blank" if body_text.blank?

    ActiveRecord::Base.transaction do
      note = Note.new(topic:, message:, author:, last_editor: author, body: body_text)
      note.save!
      mentionables, tags = rebuild_mentions_and_tags!(note, body_text)
      fan_out!(note:, mentionables:, mark_author_read: true)
      note
    end
  end

  def update!(note:, body:)
    raise Error, "You do not have permission to edit this note" unless note.author_id == author.id
    body_text = body.to_s.strip
    raise Error, "Note cannot be blank" if body_text.blank?

    ActiveRecord::Base.transaction do
      note.note_edits.create!(editor: author, body: note.body) if note.body != body_text
      note.update!(body: body_text, last_editor: author)

      mentionables, _tags = rebuild_mentions_and_tags!(note, body_text)
      fan_out!(note:, mentionables:, mark_author_read: false)
      note
    end
  end

  private

  attr_reader :author

  def rebuild_mentions_and_tags!(note, body_text)
    mention_names = extract_mentions(body_text)
    mentionables = resolve_mentions(mention_names)
    tags = extract_tags(body_text)

    note.note_mentions.delete_all
    mentionables.each do |mentionable|
      note.note_mentions.create!(mentionable:)
    end

    note.note_tags.delete_all
    tags.each do |tag|
      note.note_tags.create!(tag:)
    end

    [ mentionables, tags ]
  end

  def extract_mentions(text)
    text.to_s.scan(/(?:^|[^@\w])@([A-Za-z0-9_.-]+)/)
        .flatten
        .map { |m| NameReservation.normalize(m) }
        .reject(&:blank?)
        .uniq
  end

  def extract_tags(text)
    text.to_s.scan(/(?:^|[^#\w])#([A-Za-z0-9_.-]+)/)
        .flatten
        .map { |t| t.to_s.strip.downcase }
        .select { |tag| tag.match?(NoteTag::TAG_FORMAT) }
        .uniq
  end

  def resolve_mentions(names)
    return [] if names.empty?

    reservations = NameReservation.where(name: names).index_by(&:name)
    missing = names - reservations.keys
    raise Error, "Unknown mention: @#{missing.first}" if missing.any?

    user_ids = []
    team_ids = []

    reservations.each_value do |reservation|
      case reservation.owner_type
      when "User" then user_ids << reservation.owner_id
      when "Team" then team_ids << reservation.owner_id
      else
        raise Error, "Unsupported mention type: #{reservation.owner_type}"
      end
    end

    users = User.where(id: user_ids).index_by(&:id)
    teams = Team.where(id: team_ids).index_by(&:id)

    mentionables = names.map do |name|
      reservation = reservations[name]
      record = case reservation.owner_type
      when "User" then users[reservation.owner_id]
      when "Team" then teams[reservation.owner_id]
      end
      raise Error, "Unknown mention: @#{name}" unless record
      validate_mention_permission!(record, name)
      record
    end

    mentionables.compact.uniq
  end

  def validate_mention_permission!(mentionable, name)
    case mentionable
    when User
      unless mentionable.mentionable_by?(author)
        raise Error, "You cannot mention @#{name} (only their teammates can mention them)"
      end
    when Team
      unless mentionable.mentionable_by?(author)
        raise Error, "You cannot mention @#{name} (only team members can mention this team)"
      end
    end
  end

  def fan_out!(note:, mentionables:, mark_author_read:)
    recipient_ids = recipients_for(note, mentionables:)
    payload = {
      topic_id: note.topic_id,
      message_id: note.message_id
    }

    recipient_ids.each do |uid|
      read_at = (uid == note.author_id && mark_author_read) ? Time.current : nil
      activity = Activity.find_or_initialize_by(user_id: uid, subject: note)
      activity.activity_type ||= (uid == note.author_id ? "note_created" : "note_mentioned")
      activity.payload ||= payload
      activity.read_at ||= read_at
      activity.hidden = false
      activity.save!
    end

    Activity.where(subject: note).where.not(user_id: recipient_ids).update_all(hidden: true)
  end

  def recipients_for(note, mentionables:)
    user_ids = mentionables.select { |m| m.is_a?(User) }.map(&:id)
    team_ids = mentionables.select { |m| m.is_a?(Team) }.map(&:id)
    team_member_ids = if team_ids.any?
                        TeamMember.where(team_id: team_ids).pluck(:user_id)
    else
                        []
    end

    ([ note.author_id ] + user_ids + team_member_ids).compact.uniq
  end
end
