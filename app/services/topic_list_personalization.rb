class TopicListPersonalization
  def initialize(user:, topics:)
    @user = user
    @topics = topics.to_a
    @topic_ids = @topics.map(&:id)
    preload_states
    preload_note_counts
    preload_star_data
    preload_ignore_data
    preload_participation
  end

  def state_for(topic)
    @states[topic.id] || {}
  end

  def note_count_for(topic)
    @note_counts[topic.id].to_i
  end

  def participation_for(topic)
    @participation[topic.id] || {}
  end

  def team_readers_for(topic)
    state_for(topic)[:team_readers] || []
  end

  def star_data_for(topic)
    @star_data[topic.id] || { starred_by_me: false, team_starrers: [] }
  end

  def ignored_for(topic)
    @ignored_topic_ids.include?(topic.id)
  end

  private

  attr_reader :user, :topics, :topic_ids

  def preload_states
    @states = {}
    return if topic_ids.empty?

    last_ids = topics.index_by(&:id).transform_values(&:last_message_id)
    aware_map = ThreadAwareness.where(user:, topic_id: topic_ids)
                               .pluck(:topic_id, :aware_until_message_id)
                               .to_h
    read_counts = MessageReadRange.where(user:, topic_id: topic_ids)
                                  .group(:topic_id)
                                  .sum(:message_count)
    global_aware_before = user.aware_before
    team_readers = preload_team_readers(last_ids)

    topics.each do |topic|
      total = topic.message_count
      read_count = read_counts[topic.id].to_i
      aware_until = aware_map[topic.id]
      status = compute_status(total:, last_time: topic.last_message_at, aware_until:, read_count:, global_aware_before:)
      progress = compute_progress(total:, read_count:)
      @states[topic.id] = {
        status:, aware_until:, read_count:,
        last_id: topic.last_message_id, last_time: topic.last_message_at,
        progress:, team_readers: team_readers[topic.id] || []
      }
    end
  end

  def preload_note_counts
    @note_counts = {}
    return if topic_ids.empty?

    @note_counts = Note.visible_to(user)
                       .without_bot
                       .where(topic_id: topic_ids)
                       .active
                       .group(:topic_id)
                       .count
  end

  def preload_star_data
    @star_data = {}
    return if topic_ids.empty?

    my_stars = TopicStar.where(user:, topic_id: topic_ids).pluck(:topic_id).to_set

    team_ids = TeamMember.where(user_id: user.id).pluck(:team_id)
    team_stars = {}

    if team_ids.any?
      teammate_ids = TeamMember.where(team_id: team_ids)
                               .where.not(user_id: user.id)
                               .pluck(:user_id)

      if teammate_ids.any?
        stars = TopicStar.where(user_id: teammate_ids, topic_id: topic_ids)
                         .includes(user: { person: :default_alias })

        stars.each do |star|
          team_stars[star.topic_id] ||= []
          alias_record = star.user.person&.default_alias || star.user.aliases&.first
          team_stars[star.topic_id] << alias_record if alias_record
        end
      end
    end

    topics.each do |topic|
      @star_data[topic.id] = {
        starred_by_me: my_stars.include?(topic.id),
        team_starrers: team_stars[topic.id] || []
      }
    end
  end

  def preload_ignore_data
    @ignored_topic_ids = Set.new
    return if topic_ids.empty?

    @ignored_topic_ids = TopicIgnore.where(user:, topic_id: topic_ids).pluck(:topic_id).to_set
  end

  def preload_participation
    @participation = {}
    return if topic_ids.empty?

    my_person_id = user.person_id

    my_team_ids = TeamMember.where(user_id: user.id).select(:team_id)
    teammate_user_ids = TeamMember.where(team_id: my_team_ids).pluck(:user_id).uniq

    if teammate_user_ids.empty?
      teammate_user_ids = [ user.id ]
    end

    other_user_ids = teammate_user_ids - [ user.id ]
    teammate_person_ids = [ my_person_id ]
    teammate_person_ids += User.where(id: other_user_ids).pluck(:person_id) if other_user_ids.any?

    rows = TopicParticipant.where(topic_id: topic_ids, person_id: teammate_person_ids)
                           .select(:topic_id, :person_id)

    person_map = Person.includes(:default_alias).where(id: teammate_person_ids).index_by(&:id)

    flags = Hash.new { |h, k| h[k] = { mine: false, team: false, aliases: [] } }

    rows.each do |row|
      entry = flags[row.topic_id]
      person = person_map[row.person_id]
      next unless person

      alias_record = person.default_alias
      next unless alias_record

      entry[:aliases] << alias_record
      entry[:mine] ||= row.person_id == my_person_id
      entry[:team] = true
    end

    flags.transform_values! do |v|
      v[:aliases] = v[:aliases].uniq { |a| a.id }
      v
    end
    flags.default_proc = nil

    @participation = flags
  end

  def preload_team_readers(last_ids)
    my_team_ids = TeamMember.where(user_id: user.id).select(:team_id)
    memberships = TeamMember.where(team_id: my_team_ids).pluck(:user_id, :team_id)
    return {} if memberships.empty?

    member_user_ids = memberships.map(&:first).uniq
    team_users = User.includes(:aliases, person: [ :default_alias, :contributor_memberships ])
                     .where(id: member_user_ids)
                     .index_by(&:id)

    rows = MessageReadRange.where(user_id: memberships.map(&:first), topic_id: topic_ids)
                           .select(:topic_id, :user_id, "MAX(range_end_message_id) AS max_end")
                           .group(:topic_id, :user_id)

    result = Hash.new { |h, k| h[k] = [] }

    rows.each do |row|
      last_id = last_ids[row.topic_id]
      next unless last_id
      max_end = row.read_attribute(:max_end).to_i
      status = if max_end >= last_id
                 :read
      elsif max_end.positive?
                 :reading
      end
      next unless status
      reader = team_users[row.user_id]
      next unless reader
      reader_team_ids = memberships.select { |uid, _tid| uid == row.user_id }.map(&:second)
      result[row.topic_id] << { user: reader, status: status, team_ids: reader_team_ids }
    end

    result
  end

  def compute_status(total:, last_time:, aware_until:, read_count:, global_aware_before:)
    return :new unless aware_until || read_count.positive? || global_aware_before
    return :read if total.positive? && read_count >= total
    return :reading if read_count.positive?

    if global_aware_before && last_time && last_time <= global_aware_before
      return :aware
    end

    return :aware if aware_until
    :new
  end

  def compute_progress(total:, read_count:)
    return 0 unless total.positive?
    return 1.0 if read_count >= total

    ratio = read_count.to_f / total.to_f
    [ [ ratio, 0 ].max, 1 ].min
  end
end
