class TopicsController < ApplicationController
  before_action :set_topic, only: [:show, :aware, :read_all, :star, :unstar, :latest_patchset]
  before_action :require_authentication, only: [:aware, :aware_bulk, :aware_all, :read_all, :star, :unstar]
  before_action :require_team_membership, only: [:index, :new_topics_count]

  def index
    @search_query = nil
    base_query = apply_filters(Topic.includes(:creator))

    apply_cursor_pagination(base_query)
    preload_topic_participants
    preload_commitfest_summaries
    @new_topics_count = 0
    @page_cache_key = topics_page_cache_key

    load_visible_tags if user_signed_in?

    respond_to do |format|
      format.html
      format.turbo_stream do
        body = topics_turbo_stream_cache_fetch do
          render_to_string(:index, formats: [:turbo_stream])
        end
        render body:, content_type: "text/vnd.turbo-stream.html"
      end
    end
  end

  def new_topics_count
    @viewing_since = viewing_since_param
    base_query = topics_base_query(search_query: params[:q])
    @new_topics_count = count_new_topics(base_query, @viewing_since)
    refresh_path = params[:q].present? ? search_topics_path(q: params[:q]) : topics_path

    render partial: "new_topics_banner", locals: { count: @new_topics_count, viewing_since: @viewing_since, refresh_path: refresh_path }
  end

  def show
    messages_scope = @topic.messages.includes(
      :attachments,
      :sender,
      :sender_person,
      { sender_person: :default_alias },
      {
        reply_to: [
          :sender,
          :sender_person,
          { sender_person: :default_alias }
        ]
      }
    )

    @messages = messages_scope.order(created_at: :asc)
    @message_numbers = @messages.each_with_index.to_h { |msg, idx| [msg.id, idx + 1] }
    preload_read_state!
    auto_mark_aware!

    build_participants_sidebar_data(messages_scope)
    build_thread_outline(messages_scope)
    load_commitfest_sidebar
    if user_signed_in?
      load_notes
      load_star_state
    end

    # Check if topic has any patches (for sidebar button)
    @has_patches = @messages.any? { |msg| msg.attachments.any?(&:patch?) }
  end

  def aware
    last_id = params[:up_to_message_id].presence&.to_i || @topic.messages.maximum(:id)
    ThreadAwareness.mark_until(user: current_user, topic: @topic, until_message_id: last_id) if last_id
    respond_to do |format|
      format.json { render json: { status: "ok" } }
      format.html { head :ok }
    end
  end

  def aware_bulk
    topics_param = params[:topics]
    return render json: { error: "topics required" }, status: :unprocessable_entity unless topics_param.is_a?(Array)

    topics_param.each do |entry|
      topic = Topic.find_by(id: entry[:topic_id] || entry["topic_id"])
      next unless topic
      up_to = (entry[:up_to_message_id] || entry["up_to_message_id"]).to_i
      up_to = topic.messages.maximum(:id) if up_to.zero?
      ThreadAwareness.mark_until(user: current_user, topic:, until_message_id: up_to) if up_to
    end

    render json: { status: "ok" }
  end

  def aware_all
    timestamp = params[:before].present? ? Time.zone.parse(params[:before]) : Time.current
    current_user.update!(aware_before: [current_user.aware_before, timestamp].compact.max)

    render json: { status: "ok", aware_before: current_user.aware_before }
  end

  def read_all
    first_id = @topic.messages.minimum(:id)
    last_id = @topic.messages.maximum(:id)
    if first_id && last_id
      MessageReadRange.add_range(user: current_user, topic: @topic, start_id: first_id, end_id: last_id)
      ThreadAwareness.mark_until(user: current_user, topic: @topic, until_message_id: last_id)
    end

    respond_to do |format|
      format.json { render json: { status: "ok" } }
      format.html { redirect_to topic_path(@topic) }
    end
  end

  def star
    TopicStar.create!(user: current_user, topic: @topic)
    respond_to do |format|
      format.turbo_stream { render :update_star_state }
      format.json { render json: { starred: true } }
      format.html { redirect_to topic_path(@topic) }
    end
  rescue ActiveRecord::RecordNotUnique
    respond_to do |format|
      format.turbo_stream { render :update_star_state }
      format.json { render json: { starred: true } }
      format.html { redirect_to topic_path(@topic) }
    end
  end

  def unstar
    TopicStar.where(user: current_user, topic: @topic).destroy_all
    respond_to do |format|
      format.turbo_stream { render :update_star_state }
      format.json { render json: { starred: false } }
      format.html { redirect_to topic_path(@topic) }
    end
  end

  def latest_patchset
    latest_message = @topic.messages
                           .where(id: Attachment.where(message_id: @topic.messages.select(:id))
                                                .select(:message_id))
                           .order(created_at: :desc)
                           .find { |msg| msg.attachments.any?(&:patch?) }

    return head :not_found unless latest_message

    patches = latest_message.attachments.select(&:patch?).sort_by(&:file_name)
    return head :not_found if patches.empty?

    require 'zlib'
    require 'rubygems/package'

    tar_gz_data = StringIO.new
    Zlib::GzipWriter.wrap(tar_gz_data) do |gz|
      Gem::Package::TarWriter.new(gz) do |tar|
        patches.each do |patch|
          content = patch.decoded_body_utf8
          tar.add_file_simple(patch.file_name, 0644, content.bytesize) do |io|
            io.write(content)
          end
        end
      end
    end

    filename = "topic-#{@topic.id}-patchset.tar.gz"
    send_data tar_gz_data.string,
              filename: filename,
              type: "application/gzip",
              disposition: "attachment"
  end

  def search
    @search_query = params[:q].to_s.strip

    if @search_query.blank?
      respond_to do |format|
        format.html { redirect_to topics_path(anchor: "search") }
        format.turbo_stream { redirect_to topics_path(anchor: "search") }
      end
      return
    end

    load_cached_search_results

    preload_topic_participants
    preload_commitfest_summaries
    preload_participation_flags if user_signed_in?

    respond_to do |format|
      format.html
      format.turbo_stream { render :search }
    end
  end

  def user_state
    topic_ids = params[:topic_ids].is_a?(Array) ? params[:topic_ids].map(&:to_i).uniq : []
    return render json: { topics: {} } unless user_signed_in? && topic_ids.any?

    @topics = Topic.where(id: topic_ids)
    preload_topic_states
    preload_note_counts
    preload_participation_flags
    preload_star_counts

    payload = topic_ids.index_with do |tid|
      state = @topic_states[tid] || {}
      readers = Array(state[:team_readers]).map do |entry|
        {
          status: entry[:status],
          user_id: entry[:user]&.id,
          team_ids: entry[:team_ids]
        }
      end
      participation = @participation_flags&.dig(tid) || { mine: false, team: false, aliases: [] }
      participation_payload = {
        mine: participation[:mine],
        team: participation[:team],
        aliases_count: Array(participation[:aliases]).size
      }
      star_data = @topic_star_data&.dig(tid) || { starred_by_me: false, team_starrers: [] }
      {
        status: state[:status],
        progress: state[:progress],
        read_count: state[:read_count],
        last_id: state[:last_id],
        aware_until: state[:aware_until],
        team_readers: readers,
        note_count: @topic_note_counts&.dig(tid).to_i,
        participation: participation_payload,
        star: star_data
      }
    end

    render json: { topics: payload }
  end

  def user_state_frame
    topic_ids = params[:topic_ids].is_a?(Array) ? params[:topic_ids].map(&:to_i).uniq : []
    return head :unauthorized unless user_signed_in?
    return head :ok if topic_ids.empty?

    @topics = Topic.includes(:creator).where(id: topic_ids)
    preload_topic_states
    preload_note_counts
    preload_participation_flags
    preload_commitfest_summaries
    preload_star_counts
    preload_topic_participants

    respond_to do |format|
      format.turbo_stream
      format.html { head :not_acceptable }
    end
  end

  private

  def set_topic
    @topic = Topic.includes(
      :creator,
      :creator_person,
      creator_person: :default_alias
    ).find(params[:id])

    if @topic.merged?
      redirect_to topic_path(@topic.final_topic), status: :moved_permanently
      return
    end
  end

  def build_participants_sidebar_data(_messages_scope)
    participants = @topic.topic_participants
                         .includes(person: [:default_alias, :contributor_memberships])
                         .order(message_count: :desc, first_message_at: :asc)

    @participants = participants.map do |tp|
      alias_record = tp.person&.default_alias
      next unless alias_record

      {
        alias: alias_record,
        message_count: tp.message_count,
        first_at: tp.first_message_at,
        last_at: tp.last_message_at
      }
    end.compact
  end

  def build_thread_outline(messages_scope)
    ordered_messages = messages_scope.order(:created_at)
    children = Hash.new { |h, k| h[k] = [] }
    ordered_messages.each do |msg|
      children[msg.reply_to_id] << msg
    end

    @thread_outline = []
    traverse_thread(children, children[nil], 0, 0, @thread_outline)

    # Assign branch colors based on visual sequence: keep color if replying to previous item, otherwise rotate.
    current_color = 0
    @thread_outline.each_with_index do |entry, idx|
      if idx.zero?
        entry[:branch_index] = current_color
        next
      end

      if entry[:branching_point]
        current_color = (current_color + 1) % 6
      end

      entry[:branch_index] = current_color
    end

    assign_branch_segments!
    @has_multiple_branches = @thread_outline.map { |entry| entry[:branch_segment_index] }.uniq.size > 1

    # Build message_id -> branch_index mapping for message rendering
    @message_branch_index = @thread_outline.each_with_object({}) do |entry, hash|
      hash[entry[:message].id] = entry[:branch_index]
    end
  end

  def preload_read_state!
    return unless user_signed_in?

    ranges = MessageReadRange.where(user: current_user, topic: @topic)
                             .order(:range_start_message_id)
                             .pluck(:range_start_message_id, :range_end_message_id)
    @read_message_ids = {}
    return if ranges.empty?

    @messages.each do |msg|
      @read_message_ids[msg.id] = ranges.any? { |(s, e)| s <= msg.id && msg.id <= e }
    end
  end

  def auto_mark_aware!
    return unless user_signed_in?
    last_id = @messages.last&.id
    ThreadAwareness.mark_until(user: current_user, topic: @topic, until_message_id: last_id) if last_id
  end

  def traverse_thread(children, parent_nodes, depth, branch_depth, outline)
    return if parent_nodes.nil?

    branching_point = parent_nodes.size > 1

    parent_nodes.each do |node|
      has_multiple_children = children[node.id].size > 1
      outline << { message: node, depth: depth, branch_depth: branch_depth, branching_point: branching_point }
      child_branch_depth = branch_depth + (has_multiple_children ? 1 : 0)
      traverse_thread(children, children[node.id], depth + 1, child_branch_depth, outline)
    end
  end

  def assign_branch_segments!
    segment_index = 0
    idx = 0
    message_numbers = @message_numbers || {}

    while idx < @thread_outline.size
      start_idx = idx
      branch_id = @thread_outline[start_idx][:branch_index]

      idx += 1
      idx += 1 while idx < @thread_outline.size && @thread_outline[idx][:branch_index] == branch_id

      segment_size = idx - start_idx
      segment_entries = @thread_outline[start_idx...idx]

      segment_entries.each_with_index do |entry, relative_idx|
        entry[:branch_segment_index] = segment_index
        entry[:branch_start] = relative_idx.zero?
        entry[:branch_end] = relative_idx == segment_size - 1
        entry[:branch_size] = segment_size
        entry[:message_number] = message_numbers[entry[:message].id]
      end

      segment_index += 1
    end
  end

  def apply_cursor_pagination(base_query)
    @viewing_since = viewing_since_param

    windowed_query = base_query.joins(:messages)
                               .where(messages: { created_at: ..@viewing_since })
                               .group('topics.id')
                               .having('MAX(messages.created_at) <= ?', @viewing_since)
                               .select('topics.*, MAX(messages.created_at) as last_activity')

    if params[:cursor].present?
      cursor_time, cursor_id = params[:cursor].split('_')
      @topics = windowed_query.having('(MAX(messages.created_at), topics.id) < (?, ?)',
                                          Time.zone.parse(cursor_time), cursor_id.to_i)
    else
      @topics = windowed_query
    end

    @topics = @topics.order('MAX(messages.created_at) DESC, topics.id DESC')
                     .limit(25)
                     .load
  end

  def preload_topic_states
    topic_ids = @topics.map(&:id)
    return if topic_ids.empty?

    last_ids = @topics.index_by(&:id).transform_values(&:last_message_id)

    if user_signed_in?
      aware_map = ThreadAwareness.where(user: current_user, topic_id: topic_ids)
                                 .pluck(:topic_id, :aware_until_message_id)
                                 .to_h
      read_counts = MessageReadRange.where(user: current_user, topic_id: topic_ids)
                                    .group(:topic_id)
                                    .sum(:message_count)
      global_aware_before = current_user.aware_before

      team_readers = preload_team_reader_states(topic_ids, last_ids)
    end

    @topic_states = {}
    @topics.each do |topic|
      last_id = topic.last_message_id
      last_time = topic.last_message_at
      if user_signed_in?
        aware_until = aware_map[topic.id]
        total = topic.message_count
        read_count = read_counts[topic.id].to_i
        status = compute_topic_status(total:, last_time:, aware_until:, read_count:, global_aware_before:)
        progress = compute_progress(total:, read_count:)
      else
        status = :new
        aware_until = nil
        read_count = 0
        progress = 0
      end

      @topic_states[topic.id] = { status:, aware_until:, read_count:, last_id:, last_time:, progress:, team_readers: team_readers[topic.id] || [] }
    end
  end

  def preload_note_counts
    topic_ids = @topics.map(&:id)
    return if topic_ids.empty?

    @topic_note_counts = Note.visible_to(current_user)
                              .where(topic_id: topic_ids)
                              .active
                              .group(:topic_id)
                              .count
  end

  def preload_star_counts
    topic_ids = @topics.map(&:id)
    return if topic_ids.empty?
    return unless user_signed_in?

    my_stars = TopicStar.where(user: current_user, topic_id: topic_ids)
                        .pluck(:topic_id)
                        .to_set

    team_ids = TeamMember.where(user_id: current_user.id).pluck(:team_id)
    team_stars = {}

    if team_ids.any?
      teammate_ids = TeamMember.where(team_id: team_ids)
                               .where.not(user_id: current_user.id)
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

    @topic_star_data = {}
    @topics.each do |topic|
      @topic_star_data[topic.id] = {
        starred_by_me: my_stars.include?(topic.id),
        team_starrers: team_stars[topic.id] || []
      }
    end
  end

  def load_visible_tags
    @available_note_tags = NoteTag.joins(:note)
                                  .merge(Note.active.visible_to(current_user))
                                  .group(:tag)
                                  .order(Arel.sql("COUNT(*) DESC"))
                                  .limit(20)
                                  .count
  end

  def preload_topic_participants
    topic_ids = @topics.map(&:id)
    return if topic_ids.empty?

    # Load top 5 participants per topic, plus contributor participants
    all_participants = TopicParticipant
      .where(topic_id: topic_ids)
      .includes(person: [:default_alias, :contributor_memberships])

    @topic_participants_map = Hash.new { |h, k| h[k] = { top: [], contributors: [] } }

    # Group by topic and separate into top participants and contributors
    all_participants.group_by(&:topic_id).each do |topic_id, participants|
      sorted = participants.sort_by { |p| [-p.message_count, p.first_message_at] }
      @topic_participants_map[topic_id][:top] = sorted.first(5)
      @topic_participants_map[topic_id][:contributors] = sorted.select(&:is_contributor)
      @topic_participants_map[topic_id][:all] = sorted
    end
  end

  def preload_participation_flags
    topic_ids = @topics.map(&:id)
    return if topic_ids.empty?

    my_person_id = current_user.person_id

    my_team_ids = TeamMember.where(user_id: current_user.id).select(:team_id)
    teammate_user_ids = TeamMember.where(team_id: my_team_ids).pluck(:user_id).uniq

    if teammate_user_ids.empty?
      teammate_user_ids = [current_user.id]
    end

    other_user_ids = teammate_user_ids - [current_user.id]
    teammate_person_ids = [my_person_id]
    teammate_person_ids += User.where(id: other_user_ids).pluck(:person_id) if other_user_ids.any?

    # Use topic_participants instead of messages for efficiency
    rows = TopicParticipant.where(topic_id: topic_ids, person_id: teammate_person_ids)
                           .select(:topic_id, :person_id)

    person_map = Person.includes(:default_alias).where(id: teammate_person_ids).index_by(&:id)

    @participation_flags = Hash.new { |h, k| h[k] = { mine: false, team: false, aliases: [] } }

    rows.each do |row|
      entry = @participation_flags[row.topic_id]
      person = person_map[row.person_id]
      next unless person

      alias_record = person.default_alias
      next unless alias_record

      entry[:aliases] << alias_record
      entry[:mine] ||= row.person_id == my_person_id
      entry[:team] = true
    end

    @participation_flags.transform_values! do |v|
      v[:aliases] = v[:aliases].uniq { |a| a.id }
      v
    end
  end

  def compute_topic_status(total:, last_time:, aware_until:, read_count:, global_aware_before:)
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
    [[ratio, 0].max, 1].min
  end

  def preload_team_reader_states(topic_ids, last_ids)
    return {} unless user_signed_in?

    my_team_ids = TeamMember.where(user_id: current_user.id).select(:team_id)
    memberships = TeamMember.where(team_id: my_team_ids).pluck(:user_id, :team_id)
    return {} if memberships.empty?

    member_user_ids = memberships.map(&:first).uniq
    team_users = User.includes(:aliases, person: [:default_alias, :contributor_memberships])
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
      user = team_users[row.user_id]
      next unless user
      reader_team_ids = memberships.select { |uid, _tid| uid == row.user_id }.map(&:second)
      result[row.topic_id] << { user: user, status: status, team_ids: reader_team_ids }
    end

    result
  end

  def apply_filters(base_query)
    filter = params[:filter].to_s
    team_id = params[:team_id].presence&.to_i
    current_user_id = current_user&.id
    tag_filter = params[:note_tag].to_s.strip.downcase

    if tag_filter.present? && user_signed_in?
      visible_notes = Note.active.visible_to(current_user)
      tagged_notes = visible_notes.joins(:note_tags).where(note_tags: { tag: tag_filter })
      note_topics = tagged_notes.select(:topic_id).distinct

      base_query = base_query.joins("INNER JOIN (#{note_topics.to_sql}) tagged_notes ON tagged_notes.topic_id = topics.id")
      @active_note_tag = tag_filter
    end

    case filter
    when "no_contrib_replies"
      base_query = base_query.joins(:messages)
                             .left_joins(messages: { sender: { person: :contributor_memberships } })
                             .group('topics.id')
                             .having("COUNT(DISTINCT contributor_memberships.person_id) = 0")
    when "patch_no_replies"
      base_query = base_query.joins(messages: :attachments)
                             .group('topics.id')
                             .having('COUNT(messages.id) = 1')
                             .where("attachments.file_name ILIKE ? OR attachments.file_name ILIKE ?", "%.patch", "%.diff")
    when "reading_incomplete"
      if current_user_id
        base_query = base_query.joins(:messages)
                               .joins("LEFT JOIN message_read_ranges mrr ON mrr.topic_id = topics.id AND mrr.user_id = #{current_user_id}")
                               .group('topics.id')
                               .having("COALESCE(MAX(mrr.range_end_message_id), 0) > 0")
                               .having("COALESCE(MAX(mrr.range_end_message_id), 0) < MAX(messages.id)")
      end
    when "new_for_me"
      if current_user_id
        aware_before = current_user&.aware_before || Time.at(0)
        base_query = base_query.joins(:messages)
                               .joins("LEFT JOIN message_read_ranges mrr ON mrr.topic_id = topics.id AND mrr.user_id = #{current_user_id}")
                               .group('topics.id')
                               .having("MAX(messages.created_at) > ?", aware_before)
                               .having("COALESCE(MAX(mrr.range_end_message_id), 0) < MAX(messages.id)")
      end
    when "team_unread"
      if team_id && current_user_id
        member_ids = TeamMember.where(team_id: team_id).select(:user_id)
        base_query = base_query.joins(:messages)
                               .where.not(id: MessageReadRange.where(user_id: member_ids).select(:topic_id))
                               .group('topics.id')
      end
    when "team_reading_others"
      if team_id && current_user_id
        teammate_ids = TeamMember.where(team_id: team_id).where.not(user_id: current_user_id).select(:user_id)
        base_query = base_query.joins(:messages)
                               .joins("LEFT JOIN message_read_ranges mrr_self ON mrr_self.topic_id = topics.id AND mrr_self.user_id = #{current_user_id}")
                               .joins("INNER JOIN message_read_ranges mrr_team ON mrr_team.topic_id = topics.id AND mrr_team.user_id IN (#{teammate_ids.to_sql})")
                               .group('topics.id')
                               .having("COALESCE(MAX(mrr_self.range_end_message_id), 0) < MAX(messages.id)")
      end
    when "team_reading_any"
      if team_id && current_user_id
        member_ids = TeamMember.where(team_id: team_id).select(:user_id)
        base_query = base_query.joins(:messages)
                               .joins("INNER JOIN message_read_ranges mrr_team ON mrr_team.topic_id = topics.id AND mrr_team.user_id IN (#{member_ids.to_sql})")
                               .group('topics.id')
      end
    when "started_by_me"
      if current_user_id
        base_query = base_query.where(creator_person_id: current_user.person_id)
      end
    when "messaged_by_me"
      if current_user_id
        base_query = base_query.joins(:messages).where(messages: { sender_person_id: current_user.person_id }).distinct
      end
    when "team_started"
      if team_id
        member_person_ids = User.joins(:team_members).where(team_members: { team_id: team_id }).select(:person_id)
        base_query = base_query.where(creator_person_id: member_person_ids)
      end
    when "team_messaged"
      if team_id
        member_person_ids = User.joins(:team_members).where(team_members: { team_id: team_id }).select(:person_id)
        base_query = base_query.where(id: Message.where(sender_person_id: member_person_ids).select(:topic_id))
      end
    when "starred_by_me"
      if current_user_id
        base_query = base_query.joins(:topic_stars)
                               .where(topic_stars: { user_id: current_user_id })
      end
    when "starred_by_team"
      if team_id && current_user_id
        member_ids = TeamMember.where(team_id: team_id).select(:user_id)
        base_query = base_query.joins(:topic_stars)
                               .where(topic_stars: { user_id: member_ids })
                               .distinct
      end
    end
    base_query
  end

  def apply_state_filters
    filter = params[:filter].to_s
    return if filter.blank?
    return unless @topic_states
    team_id = params[:team_id].presence&.to_i

    case filter
    when "reading_incomplete"
      @topics = @topics.select { |t| @topic_states.dig(t.id, :status) == :reading }
    when "new_for_me"
      aware_before = current_user.aware_before
      @topics = @topics.select do |t|
        state = @topic_states[t.id] || {}
        last_time = state[:last_time]
        last_id = state[:last_id]
        aware_until = state[:aware_until]
        status = state[:status]

        newer_than_global = aware_before.nil? || (last_time && last_time > aware_before)
        missing_latest = last_id && (!aware_until || aware_until < last_id)
        not_read = status != :read

        newer_than_global && missing_latest && not_read
      end
    when "team_unread"
      @topics = @topics.select do |t|
        team_readers = filter_team_readers(t, team_id: team_id)
        team_readers.empty?
      end
    when "team_reading_others"
      @topics = @topics.select do |t|
        state = @topic_states[t.id] || {}
        my_status = state[:status]
        team_readers = filter_team_readers(t, team_id: team_id)
        team_readers.any? && my_status != :read && my_status != :reading
      end
    when "team_reading_any"
      @topics = @topics.select do |t|
        team_readers = filter_team_readers(t, team_id: team_id)
        team_readers.any?
      end
    end

    topic_ids = @topics.map(&:id)
    @topic_states.slice!(*topic_ids) if topic_ids.any?
  end

  def filter_team_readers(topic, team_id:)
    readers = @topic_states.dig(topic.id, :team_readers) || []
    return readers unless team_id
    readers.select { |r| r[:team_id] == team_id }
  end

  def topics_base_query(search_query: nil)
    return apply_filters(Topic.includes(:creator)) if search_query.nil?

    cleaned_query = search_query.to_s.strip
    return Topic.none if cleaned_query.blank?

    build_search_query(cleaned_query)
  end

  def build_search_query(query)
    cleaned_query = query.to_s.strip
    return Topic.none if cleaned_query.blank?

    search_pattern = "%#{ActiveRecord::Base.sanitize_sql_like(cleaned_query)}%"

    title_sql = Topic.select(:id).where("title ILIKE ?", search_pattern).to_sql
    message_sql = Message.select(:topic_id).where("body ILIKE ?", search_pattern).to_sql
    union_sql = "(#{title_sql}) UNION (#{message_sql})"

    Topic.where("topics.id IN (#{union_sql})")
         .includes(:creator)
  end

  def viewing_since_param
    if params[:viewing_since].present?
      Time.zone.parse(params[:viewing_since])
    else
      Time.current
    end
  end

  def count_new_topics(base_query, viewing_since)
    base_query.joins(:messages)
              .where(messages: { created_at: viewing_since.. })
              .group('topics.id')
              .having('MAX(messages.created_at) > ?', viewing_since)
              .count
              .size
  end

  def load_notes
    notes = Note.active.visible_to(current_user)
                .where(topic: @topic)
                .includes(
                  :note_tags,
                  { author: { person: :default_alias } },
                  { last_editor: { person: :default_alias } },
                  { note_mentions: :mentionable }
                )
                .order(:created_at)

    @notes_by_message = Hash.new { |h, k| h[k] = [] }
    notes.each do |note|
      key = note.message_id || :thread
      @notes_by_message[key] << note
    end
  end

  def load_star_state
    @is_starred = TopicStar.exists?(user: current_user, topic: @topic)
  end

  def load_cached_search_results
    @viewing_since = viewing_since_param
    longpage = params[:longpage].to_i
    cache = SearchResultCache.new(query: @search_query, scope: "title_body", viewing_since: @viewing_since, longpage: longpage)

    result = cache.fetch do |limit, offset|
      build_search_query(@search_query)
        .joins(:messages)
        .where(messages: { created_at: ..@viewing_since })
        .group('topics.id')
        .select('topics.id, topics.creator_id, MAX(messages.created_at) as last_activity')
        .order('MAX(messages.created_at) DESC, topics.id DESC')
        .limit(limit)
        .offset(offset)
        .load
    end

    entries = result[:entries] || []
    sliced = slice_cached_entries(entries, params[:cursor])

    if sliced[:entries].empty? && entries.size >= SearchResultCache::LONGPAGE_SIZE
      longpage += 1
      cache = SearchResultCache.new(query: @search_query, scope: "title_body", viewing_since: @viewing_since, longpage: longpage)
      next_result = cache.fetch do |limit, offset|
        build_search_query(@search_query)
          .joins(:messages)
          .where(messages: { created_at: ..@viewing_since })
          .group('topics.id')
          .select('topics.id, topics.creator_id, MAX(messages.created_at) as last_activity')
          .order('MAX(messages.created_at) DESC, topics.id DESC')
          .limit(limit)
          .offset(offset)
          .load
      end
      entries = next_result[:entries] || []
      sliced = slice_cached_entries(entries, params[:cursor])
    end

    @current_longpage = longpage
    @topics = hydrate_topics_from_entries(sliced[:entries])
    @topics = [] unless @topics
    @new_topics_count = 0
  end

  def preload_commitfest_summaries
    topic_ids = @topics.map(&:id)
    @commitfest_summaries = Topic.commitfest_summaries(topic_ids)
  end

  def load_commitfest_sidebar
    entries = CommitfestPatchCommitfest
      .joins(commitfest_patch: :commitfest_patch_topics)
      .includes(:commitfest, commitfest_patch: :commitfest_tags)
      .where(commitfest_patch_topics: { topic_id: @topic.id })
      .order("commitfests.end_date DESC, commitfests.start_date DESC")

    deduped_entries = entries.uniq { |entry| entry.commitfest_patch.external_id }

    @commitfest_sidebar_entries = deduped_entries.map do |entry|
      patch = entry.commitfest_patch
      {
        commitfest_name: entry.commitfest.name,
        commitfest_external_id: entry.commitfest.external_id,
        patch_external_id: patch.external_id,
        patch_title: patch.title,
        status: entry.status,
        tags: patch.commitfest_tags.map(&:name)
      }
    end

    reviewers = deduped_entries.flat_map { |entry| Topic.parse_csv_list(entry.commitfest_patch.reviewers) }
    @commitfest_reviewers = reviewers.uniq

    committers = deduped_entries.map { |entry| entry.commitfest_patch.committer.to_s.strip }.reject(&:blank?).uniq
    @commitfest_committers = committers
  end

  def slice_cached_entries(entries, cursor_param)
    return { entries: entries.first(25) } unless cursor_param.present?

    cursor_time_str, cursor_id_str = cursor_param.split('_')
    cursor_time = Time.zone.parse(cursor_time_str)
    cursor_id = cursor_id_str.to_i

    start_index = entries.find_index do |entry|
      entry_time = entry[:last_activity]
      next false unless entry_time
      (entry_time < cursor_time) || (entry_time == cursor_time && entry[:id].to_i < cursor_id)
    end

    start_index ||= entries.size
    { entries: entries.drop(start_index).first(25) }
  end

  def hydrate_topics_from_entries(entries)
    ids = entries.map { |e| e[:id] }
    return [] if ids.empty?

    topics_map = Topic.includes(:creator).where(id: ids).index_by(&:id)
    entries.filter_map do |entry|
      topic = topics_map[entry[:id]]
      next unless topic
      last_activity = entry[:last_activity]
      topic.define_singleton_method(:last_activity) { last_activity }
      topic
    end
  end

  def topics_page_cache_key
    return nil unless @topics&.first
    return nil if params[:filter].present? || params[:team_id].present?
    return nil if params[:note_tag].present?

    latest_topic = @topics.first
    watermark = "#{latest_topic.last_activity.to_i}_#{latest_topic.id}"
    ["topics-index", watermark]
  end

  def topics_turbo_stream_cache_key
    [
      "topics-index-turbo",
      params[:filter],
      params[:team_id],
      params[:cursor].presence || "root"
    ]
  end

  def topics_turbo_stream_cache_read
    Rails.cache.read(topics_turbo_stream_cache_key)
  end

  def topics_turbo_stream_cache_fetch
    return yield if params[:filter].present? || params[:team_id].present? || params[:note_tag].present?

    Rails.cache.fetch(topics_turbo_stream_cache_key, expires_in: 10.minutes) { yield }
  end

  def require_team_membership
    team_id = params[:team_id].presence&.to_i
    return unless team_id

    unless user_signed_in?
      redirect_to new_session_path, alert: "Please sign in"
      return
    end

    team = Team.find_by(id: team_id)
    render_404 and return unless team
    render_404 unless team.member?(current_user)
  end
end
