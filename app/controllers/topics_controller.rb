class TopicsController < ApplicationController
  include DraftSidebarLoader

  before_action :set_topic, only: [ :show, :message_batch, :attachments_sidebar, :patchsets_sidebar, :aware, :read_all, :unread_all, :star, :unstar, :ignore, :unignore, :latest_patchset, :summary, :messages ]
  before_action :require_authentication, only: [ :aware, :read_all, :unread_all, :star, :unstar, :ignore, :unignore, :row_states ]

  TOPIC_LIST_PRELOADS = [ :creator, { creator_person: :default_alias }, { last_sender_person: :default_alias } ].freeze
  ROW_STATES_LIMIT = 50

  def index
    if user_signed_in? && request.path == root_path
      default_search = current_user.default_saved_search
      return redirect_to search_topics_path(saved_search_id: default_search.id) if default_search
    end

    @search_query = nil
    base_query = Topic.includes(*TOPIC_LIST_PRELOADS)
    base_query = apply_default_ignore_filter(base_query) if user_signed_in?

    apply_cursor_pagination(base_query)
    preload_topic_participants
    preload_commitfest_summaries
    preload_commit_summaries
    preload_ci_statuses
    preload_topic_mailing_lists
    @new_topics_count = 0

    if user_signed_in?
      @personalization = TopicListPersonalization.new(user: current_user, topics: @topics)
      load_visible_tags
    end

    load_saved_searches
    @all_mailing_lists = MailingList.order(:display_name)

    respond_to do |format|
      format.html
      format.turbo_stream
    end
  end

  def new_topics_count
    @viewing_since = viewing_since_param

    search_query = if params[:saved_search_id].present?
      base_scope = SavedSearch.visible_to(user_signed_in? ? current_user : nil)
      saved_search = base_scope.find(params[:saved_search_id])
      if params[:team_id].present? && saved_search.scope_team?
        saved_search.resolve_query(team: Team.find(params[:team_id]))
      else
        saved_search.resolve_query
      end
    else
      params[:q]
    end

    base_query = topics_base_query(search_query: search_query)
    @new_topics_count = count_new_topics(base_query, @viewing_since)

    refresh_params = params[:saved_search_id].present? ? { saved_search_id: params[:saved_search_id], team_id: params[:team_id] }.compact : { q: params[:q] }
    refresh_path = search_query.present? ? search_topics_path(**refresh_params) : topics_path

    render partial: "new_topics_banner", locals: { count: @new_topics_count, viewing_since: @viewing_since, refresh_path: refresh_path }
  end

  # Rows never disappear here: no apply_default_ignore_filter, an ignored
  # topic still gets replaced so its icon stays in sync.
  def row_states
    ids = row_state_topic_ids
    @topics = ids.empty? ? [] : Topic.includes(*TOPIC_LIST_PRELOADS).where(id: ids).to_a

    preload_topic_participants
    preload_commitfest_summaries
    preload_commit_summaries
    preload_ci_statuses
    preload_topic_mailing_lists
    @personalization = TopicListPersonalization.new(user: current_user, topics: @topics)

    respond_to do |format|
      format.turbo_stream
    end
  end

  def show
    message_columns = (Message.column_names - %w[body body_tsv]).map { |c| "messages.#{c}" }
    messages_scope = @topic.messages
      .select(message_columns)
      .preload(
        :sender,
        :sender_person,
        { sender_person: :default_alias }
      )

    @messages = messages_scope.order(created_at: :asc)
    @message_numbers = @messages.each_with_index.to_h { |msg, idx| [ msg.id, idx + 1 ] }
    wire_reply_to_from_loaded_messages!
    preload_read_state!
    auto_mark_aware!
    load_inline_message_bodies!

    build_participants_sidebar_data(messages_scope)
    build_thread_outline(@messages)
    load_commitfest_sidebar
    load_commit_sidebar
    # lazy object, not a load_* call like its neighbours - the view decides
    # whether anything is needed, so this must not query on its own
    @ci_status = PatchCi::TopicStatus.new(topic: @topic)

    @topic_mailing_lists = @topic.mailing_lists.to_a
    @topic_is_multi_list = @topic_mailing_lists.size > 1

    if @topic_is_multi_list
      msg_ids = @messages.map(&:id)
      mml_records = MessageMailingList.where(message_id: msg_ids).includes(:mailing_list)
      @message_mailing_lists_map = mml_records.group_by(&:message_id)
                                               .transform_values { |mmls| mmls.map(&:mailing_list) }
    end

    if user_signed_in?
      load_notes
      load_star_state
      @drafts_by_parent = current_user.outgoing_drafts
                                       .where.not(status: OutgoingDraft::STATUS_SENT)
                                       .where(topic_id: @topic.id)
                                       .index_by(&:reply_to_message_id)
      @sidebar_drafts = @drafts_by_parent.values
                                          .sort_by { |d| @message_numbers[d.reply_to_message_id] || Float::INFINITY }
    else
      @drafts_by_parent = {}
      @sidebar_drafts = []
    end

    @has_patches = @topic.messages.where(is_patch_submission: true).exists?
    if @has_patches
      latest_message = latest_patchset_message
      if latest_message
        patch_attachments = latest_message.attachments.select(&:patch_submission_candidate?)
        totals = patch_attachments.reduce({ added: 0, removed: 0 }) do |acc, attachment|
          stats = attachment.diff_line_stats
          acc[:added] += stats[:added]
          acc[:removed] += stats[:removed]
          acc
        end
        @latest_patchset_stats = totals
      end
    end
  end

  def message_batch
    ids = params[:ids].to_s.split(",").map(&:to_i).reject(&:zero?).first(50)
    return head :bad_request if ids.empty?

    @messages = @topic.messages
      .where(id: ids)
      .eager_load(:sender, :sender_person, { sender_person: :default_alias })
      .preload(:attachments)
      .order(:created_at)

    expires_in 1.year, public: true
    render layout: false
  end

  def attachments_sidebar
    message_columns = (Message.column_names - %w[body body_tsv]).map { |c| "messages.#{c}" }
    messages = @topic.messages
      .select(message_columns)
      .preload(:attachments)
      .order(created_at: :asc)

    @attachment_messages = messages.select { |msg| msg.attachments.any? }
    @message_numbers = messages.each_with_index.to_h { |msg, idx| [ msg.id, idx + 1 ] }

    render layout: false
  end

  def patchsets_sidebar
    message_columns = (Message.column_names - %w[body body_tsv]).map { |c| "messages.#{c}" }
    messages = @topic.messages
      .select(message_columns)
      .order(created_at: :asc)

    @message_numbers = messages.each_with_index.to_h { |msg, idx| [ msg.id, idx + 1 ] }
    @patchset_messages = messages
      .select(&:is_patch_submission)
      .sort_by(&:created_at)
      .reverse

    # a row with no pushed_at has no branch on github yet, but it still counts
    # as CI history worth linking to
    branches = PatchBranch.where(topic_id: @topic.id).pluck(:message_id, :branch_name, :pushed_at)
    @has_patch_branches = branches.any?
    @patchset_branches = branches.filter_map { |message_id, name, pushed_at| [ message_id, name ] if pushed_at }.to_h

    render layout: false
  end

  def aware
    last_id = params[:up_to_message_id].presence&.to_i || @topic.messages.maximum(:id)
    ThreadAwareness.mark_until(user: current_user, topic: @topic, until_message_id: last_id) if last_id
    respond_to do |format|
      format.json { render json: { status: "ok" } }
      format.html { head :ok }
    end
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

  def unread_all
    MessageReadRange.where(user: current_user, topic: @topic).delete_all

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

  def ignore
    TopicIgnore.find_or_create_by!(user: current_user, topic: @topic)
    respond_to do |format|
      format.turbo_stream { render :update_ignore_state }
      format.json { render json: { ignored: true } }
      format.html { redirect_to topic_path(@topic) }
    end
  rescue ActiveRecord::RecordNotUnique
    respond_to do |format|
      format.turbo_stream { render :update_ignore_state }
      format.json { render json: { ignored: true } }
      format.html { redirect_to topic_path(@topic) }
    end
  end

  def unignore
    TopicIgnore.where(user: current_user, topic: @topic).destroy_all
    respond_to do |format|
      format.turbo_stream { render :update_ignore_state }
      format.json { render json: { ignored: false } }
      format.html { redirect_to topic_path(@topic) }
    end
  end

  def latest_patchset
    latest_message = latest_patchset_message
    return head :not_found unless latest_message

    archive = PatchsetArchive.build(
      message: latest_message,
      attachment_number: @topic.chronological_index_of(latest_message),
      host: request.host_with_port
    )
    return head :not_found unless archive

    send_data archive[:data],
              filename: "topic-#{@topic.id}-patchset.tar.gz",
              type: "application/gzip",
              disposition: "attachment"
  end

  def summary
    messages = @topic.messages.order(created_at: :asc)
    message_numbers = messages.each_with_index.to_h { |msg, idx| [ msg.id, idx + 1 ] }

    patchset_messages = @topic.messages
      .where(is_patch_submission: true)
      .preload(:attachments, sender_person: :default_alias, sender: {})
      .order(created_at: :asc)

    creator_alias = @topic.creator_display_alias

    mailing_lists = @topic.mailing_lists.order(:display_name).map do |ml|
      { id: ml.id, identifier: ml.identifier, display_name: ml.display_name }
    end

    patchsets = patchset_messages.map do |msg|
      sender_alias = msg.sender_display_alias
      patch_count = msg.attachments.count(&:patch_submission_candidate?)
      {
        message_id: msg.id,
        message_number: message_numbers[msg.id],
        external_message_id: msg.message_id,
        subject: msg.subject,
        submitted_at: msg.created_at&.iso8601,
        submitted_by: alias_payload(sender_alias),
        patch_count: patch_count,
        download_url: message_patchset_url(msg)
      }
    end

    render json: {
      id: @topic.id,
      title: @topic.title,
      url: topic_url(@topic),
      created_at: @topic.created_at&.iso8601,
      last_message_at: @topic.last_message_at&.iso8601,
      message_count: @topic.message_count,
      participant_count: @topic.participant_count,
      creator: alias_payload(creator_alias),
      mailing_lists: mailing_lists,
      patchsets: patchsets
    }
  end

  def messages
    msgs = @topic.messages
      .preload(:attachments, sender_person: :default_alias, sender: {})
      .order(created_at: :asc)

    payload = msgs.map do |msg|
      sender_alias = msg.sender_display_alias
      attachments = msg.attachments.map do |att|
        {
          id: att.id,
          file_name: att.file_name,
          content_type: att.content_type,
          url: attachment_url(att)
        }
      end

      {
        id: msg.id,
        external_message_id: msg.message_id,
        subject: msg.subject,
        created_at: msg.created_at&.iso8601,
        reply_to_id: msg.reply_to_id,
        sender: alias_payload(sender_alias),
        is_patch_submission: msg.is_patch_submission,
        body: msg.body,
        attachments: attachments
      }
    end

    render json: {
      topic_id: @topic.id,
      title: @topic.title,
      messages: payload
    }
  end

  def search
    if params[:saved_search_id].present?
      base_scope = SavedSearch.visible_to(user_signed_in? ? current_user : nil)
      @saved_search = base_scope.find(params[:saved_search_id])
      if params[:team_id].present? && @saved_search.scope_team?
        @saved_search_team = Team.find(params[:team_id])
        @search_query = @saved_search.resolve_query(team: @saved_search_team)
      else
        @search_query = @saved_search.resolve_query
      end
    else
      @search_query = params[:q].to_s.strip
    end

    @viewing_since = viewing_since_param
    @new_topics_count = 0

    if @search_query.blank?
      respond_to do |format|
        format.html { redirect_to topics_path(anchor: "search") }
        format.turbo_stream { redirect_to topics_path(anchor: "search") }
      end
      return
    end

    @search_warnings = []

    begin
      # Parse the search query
      parser = Search::QueryParser.new
      ast = parser.parse(@search_query)

      # Validate and collect warnings
      validator = Search::QueryValidator.new(ast)
      validated = validator.validate
      @search_warnings += validated.warnings

      # Build the ActiveRecord query
      builder = Search::QueryBuilder.new(ast: validated.ast, user: current_user)
      result = builder.build
      @search_warnings += result.warnings

      # Load results
      load_search_results(result.relation)
    rescue Parslet::ParseFailed => e
      @search_error = format_parse_error(e)
      @topics = []
    end

    preload_topic_participants
    preload_commitfest_summaries
    preload_commit_summaries
    preload_ci_statuses
    preload_topic_mailing_lists
    @personalization = TopicListPersonalization.new(user: current_user, topics: @topics) if user_signed_in?
    load_visible_tags if user_signed_in?
    load_saved_searches
    @all_mailing_lists = MailingList.order(:display_name)

    respond_to do |format|
      format.html
      format.turbo_stream { render :search }
    end
  end

  private

  def parse_time_param(value)
    return nil if value.blank?
    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end

  def row_state_topic_ids
    raw = params[:topic_ids]
    raw = [ raw ] unless raw.is_a?(Array)

    raw.filter_map { |id| Integer(id.to_s, 10, exception: false) }
       .select(&:positive?)
       .uniq
       .first(ROW_STATES_LIMIT)
  end

  def alias_payload(alias_record)
    return nil unless alias_record
    { name: alias_record.name, email: alias_record.email }
  end

  def latest_patchset_message
    @latest_patchset_message ||= @topic.messages
      .where(is_patch_submission: true)
      .order(created_at: :desc)
      .preload(:attachments)
      .first
  end

  def set_topic
    @topic = Topic.includes(
      :creator,
      :creator_person,
      creator_person: :default_alias
    ).find(params[:id])

    if @topic.merged?
      redirect_to topic_path(@topic.final_topic), status: :moved_permanently
      nil
    end
  end

  def build_participants_sidebar_data(_messages_scope)
    participants = @topic.topic_participants
                         .includes(person: [ :default_alias, :contributor_memberships ])
                         .order(message_count: :desc, first_message_at: :asc)

    @participants = participants.map do |tp|
      alias_record = tp.person&.default_alias
      next unless alias_record

      {
        alias: alias_record,
        person: tp.person,
        message_count: tp.message_count,
        first_at: tp.first_message_at,
        last_at: tp.last_message_at
      }
    end.compact
  end

  def build_thread_outline(messages)
    children = Hash.new { |h, k| h[k] = [] }
    messages.each do |msg|
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

  def wire_reply_to_from_loaded_messages!
    messages_by_id = @messages.index_by(&:id)
    @messages.each do |msg|
      target = msg.reply_to_id ? messages_by_id[msg.reply_to_id] : nil
      msg.association(:reply_to).target = target
    end
  end

  def load_inline_message_bodies!
    inline_ids = compute_inline_message_ids
    return if inline_ids.empty?

    full_messages = Message
      .where(id: inline_ids)
      .eager_load(:sender, :sender_person, { sender_person: :default_alias },
                  { reply_to: [ :sender, :sender_person, { sender_person: :default_alias } ] })
      .preload(:attachments)
      .index_by(&:id)

    @messages = @messages.map { |msg| full_messages[msg.id] || msg }
  end

  def compute_inline_message_ids
    ids = []
    @messages.each do |msg|
      is_read = user_signed_in? && @read_message_ids&.dig(msg.id)
      next if is_read
      ids << msg.id
      break if ids.size >= 20
    end
    ids
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

  # Starring always wins: an ignored-and-starred topic still appears.
  def apply_default_ignore_filter(base_query)
    user_id = current_user.id
    base_query.where(
      "topics.id NOT IN (SELECT topic_id FROM topic_ignores WHERE user_id = ?) " \
      "OR topics.id IN (SELECT topic_id FROM topic_stars WHERE user_id = ?)",
      user_id, user_id
    )
  end

  def apply_cursor_pagination(base_query)
    @viewing_since = viewing_since_param

    @topics = activity_window(base_query, limit: 25, cursor: params[:cursor],
                              preload: TOPIC_LIST_PRELOADS).load
  end

  # Topics ordered by their latest message as of viewing_since.
  #
  # Aggregating MAX(messages.created_at) cannot be short-circuited by the LIMIT --
  # every group has to be computed before the top N is known. Split on
  # viewing_since instead: topics at or below it read the indexed
  # topics.last_message_at, and only topics that have moved past it need a real
  # MAX, which is bounded by activity since the page loaded.
  #
  # Built from a clean Topic scope rather than by unscoping base_query, whose
  # left_joins would multiply rows again; only its id restriction is wanted.
  def activity_window(base_query, limit:, offset: 0, cursor: nil, select: "topics.*", preload: nil)
    cursor_time, cursor_id = parse_activity_cursor(cursor)
    ids = activity_id_restriction(base_query)

    settled = settled_activity_scope(ids, cursor_time, cursor_id).limit(limit + offset)
    recent = recent_activity_scope(ids, cursor_time, cursor_id)

    candidates = "(#{settled.to_sql}) UNION ALL (#{recent.to_sql})"

    scope = Topic.select("#{select}, activity.last_activity")
                 .from(Arel.sql("(#{candidates}) AS activity"))
                 .joins("INNER JOIN topics ON topics.id = activity.id")
                 .order(Arel.sql("activity.last_activity DESC, activity.id DESC"))
                 .limit(limit)
                 .offset(offset)

    preload ? scope.preload(*preload) : scope
  end

  # Taking only the first limit+offset settled rows is safe: they are ordered by
  # the same key as the merged result, so a settled row outside that prefix can
  # never outrank one inside it.
  def settled_activity_scope(ids, cursor_time, cursor_id)
    scope = activity_base_scope(ids).where(last_message_at: ..@viewing_since)
    scope = scope.where("(topics.last_message_at, topics.id) < (?, ?)", cursor_time, cursor_id) if cursor_time
    scope.select("topics.id, topics.last_message_at AS last_activity")
         .order(Arel.sql("topics.last_message_at DESC, topics.id DESC"))
  end

  def recent_activity_scope(ids, cursor_time, cursor_id)
    scope = activity_base_scope(ids)
              .where("topics.last_message_at > ?", @viewing_since)
              .joins(Arel.sql(ActiveRecord::Base.sanitize_sql_array([ <<~SQL.squish, @viewing_since ])))
                CROSS JOIN LATERAL (
                  SELECT MAX(messages.created_at) AS last_activity
                  FROM messages
                  WHERE messages.topic_id = topics.id AND messages.created_at <= ?
                ) snapshot
              SQL
              .where("snapshot.last_activity IS NOT NULL")
    scope = scope.where("(snapshot.last_activity, topics.id) < (?, ?)", cursor_time, cursor_id) if cursor_time
    scope.select("topics.id, snapshot.last_activity")
  end

  # Merged topics keep a stale last_message_at but own no messages, so the old
  # INNER JOIN on messages dropped them. Ordering by the column would surface
  # them, hence the explicit filter.
  def activity_base_scope(ids)
    scope = Topic.where(merged_into_topic_id: nil)
    ids ? scope.where(id: ids) : scope
  end

  # Search relations left_join commitfest tables and can return a topic more
  # than once; the aggregate used to collapse those rows. Restricting by id
  # subquery keeps the outer scan on topics alone, so it dedupes and stays
  # indexable at the same time.
  def activity_id_restriction(base_query)
    return nil unless activity_query_needs_dedup?(base_query)

    base_query.unscope(:includes, :eager_load, :order, :limit, :offset, :select).select("topics.id")
  end

  def activity_query_needs_dedup?(base_query)
    base_query.where_clause.any? || base_query.joins_values.any? || base_query.left_outer_joins_values.any?
  end

  def parse_activity_cursor(cursor)
    return [ nil, nil ] if cursor.blank?

    cursor_time, cursor_id = cursor.split("_")
    [ Time.zone.parse(cursor_time), cursor_id.to_i ]
  end

  def load_visible_tags
    @available_note_tags = NoteTag.joins(:note)
                                  .merge(Note.active.visible_to(current_user))
                                  .group(:tag)
                                  .order(Arel.sql("COUNT(*) DESC"))
                                  .limit(20)
                                  .count
  end

  def load_saved_searches
    @saved_searches = if user_signed_in?
      SavedSearch.visible_to_unhidden(current_user).order(:scope, :position, :name)
    else
      SavedSearch.scope_global.order(:position, :name)
    end
  end

  def preload_topic_mailing_lists
    topic_ids = @topics.map(&:id)
    return if topic_ids.empty?

    @topic_mailing_lists_map = TopicMailingList
      .where(topic_id: topic_ids)
      .includes(:mailing_list)
      .group_by(&:topic_id)
      .transform_values { |tmls| tmls.map(&:mailing_list) }
  end

  def preload_topic_participants
    topic_ids = @topics.map(&:id)
    return if topic_ids.empty?

    # Load top 5 participants per topic, plus contributor participants
    all_participants = TopicParticipant
      .where(topic_id: topic_ids)
      .includes(person: [ :default_alias, :contributor_memberships ])

    @topic_participants_map = Hash.new { |h, k| h[k] = { top: [], contributors: [] } }

    # Group by topic and separate into top participants and contributors
    all_participants.group_by(&:topic_id).each do |topic_id, participants|
      sorted = participants.sort_by { |p| [ -p.message_count, p.first_message_at ] }
      @topic_participants_map[topic_id][:top] = sorted.first(5)
      @topic_participants_map[topic_id][:contributors] = sorted.select(&:is_contributor)
      @topic_participants_map[topic_id][:all] = sorted
    end
  end

  def topics_base_query(search_query: nil)
    return Topic.includes(*TOPIC_LIST_PRELOADS) if search_query.nil?

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
  end

  def viewing_since_param
    if params[:viewing_since].present?
      Time.zone.parse(params[:viewing_since])
    else
      Time.current
    end
  end

  # A topic has a message newer than viewing_since exactly when its latest
  # message is newer, so the indexed column answers this without grouping.
  def count_new_topics(base_query, viewing_since)
    base_query.unscope(:includes, :order, :limit, :offset, :select)
              .where(merged_into_topic_id: nil)
              .where("topics.last_message_at > ?", viewing_since)
              .distinct
              .count(:id)
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

  SEARCH_PAGE_SIZE = 1000

  def load_search_results(base_relation)
    @viewing_since = viewing_since_param
    longpage = params[:longpage].to_i

    entries = execute_search_query(base_relation, longpage)
    sliced = slice_cached_entries(entries, params[:cursor])

    # Handle pagination to next longpage if needed
    if sliced[:entries].empty? && entries.size >= SEARCH_PAGE_SIZE
      longpage += 1
      entries = execute_search_query(base_relation, longpage)
      sliced = slice_cached_entries(entries, params[:cursor])
    end

    @current_longpage = longpage
    @topics = hydrate_topics_from_entries(sliced[:entries])
    @topics = [] unless @topics
    @new_topics_count = 0
  end

  def execute_search_query(base_relation, longpage)
    results = activity_window(
      base_relation,
      limit: SEARCH_PAGE_SIZE,
      offset: SEARCH_PAGE_SIZE * longpage,
      select: "topics.id, topics.creator_id"
    ).load

    results.map do |row|
      {
        id: row.id,
        last_activity: row.try(:last_activity)&.to_time || row.try(:created_at)&.to_time
      }
    end
  end

  def format_parse_error(error)
    # Extract user-friendly error message from Parslet error
    cause = error.parse_failure_cause
    if cause
      line = cause.pos.line_and_column.first rescue 1
      "Syntax error at position #{line}: #{cause.message}"
    else
      "Invalid search syntax"
    end
  rescue StandardError
    "Invalid search syntax"
  end

  def preload_commitfest_summaries
    topic_ids = @topics.map(&:id)
    @commitfest_summaries = Topic.commitfest_summaries(topic_ids)
  end

  def preload_commit_summaries
    topic_ids = @topics.select { |topic| topic.commit_count.to_i.positive? }.map(&:id)
    @commit_summaries = Topic.commit_summaries(topic_ids)
  end

  def preload_ci_statuses
    @ci_repo_state = PatchCiRepoState.current
    @ci_statuses = PatchCi::CurrentPatchsets.new(repo_state: @ci_repo_state)
                                            .load(@topics.map(&:id))
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

  def load_commit_sidebar
    commits = Commit.for_topic(@topic.id).to_a
    @commit_groups = Commit.group_backports(commits)
    @commit_credits = commit_credits_for(commits)
  end

  # role => [{ name:, email: }], deduplicated across a change and its backports.
  def commit_credits_for(commits)
    return {} if commits.empty?

    rows = CommitPerson.where(commit_id: commits.map(&:id))
                       .includes(person: :default_alias)
    grouped = rows.group_by(&:role)

    CommitPerson::DISPLAY_ORDER.each_with_object({}) do |role, acc|
      entries = (grouped[role] || []).map do |row|
        alias_record = row.person&.default_alias
        {
          name: row.raw_name.presence || alias_record&.name || row.raw_email,
          email: alias_record&.email
        }
      end

      # dedupe by name, but a resolved (linked) entry wins over an unresolved
      # duplicate of the same name -- otherwise a name colliding with an
      # earlier unresolved row would silently drop its person link.
      deduped = entries.group_by { |entry| entry[:name].to_s.downcase }.map do |_, dups|
        dups.find { |entry| entry[:email].present? } || dups.first
      end

      acc[role] = deduped if deduped.any?
    end
  end

  def slice_cached_entries(entries, cursor_param)
    return { entries: entries.first(25) } unless cursor_param.present?

    cursor_time_str, cursor_id_str = cursor_param.split("_")
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

    topics_map = Topic.includes(*TOPIC_LIST_PRELOADS).where(id: ids).index_by(&:id)
    entries.filter_map do |entry|
      topic = topics_map[entry[:id]]
      next unless topic
      last_activity = entry[:last_activity]
      topic.define_singleton_method(:last_activity) { last_activity }
      topic
    end
  end
end
