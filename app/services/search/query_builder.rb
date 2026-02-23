# frozen_string_literal: true

module Search
  # Converts AST to ActiveRecord relation.
  # Handles all selector types, boolean logic, and negation.
  class QueryBuilder
    Result = Struct.new(:relation, :warnings, keyword_init: true)

    ALLOWED_COUNT_COLUMNS = %i[message_count participant_count contributor_participant_count].freeze
    ALLOWED_DATE_COLUMNS = %i[created_at last_message_at].freeze

    def initialize(ast:, user:)
      @ast = ast
      @user = user
      @warnings = []
      @value_resolver = ValueResolver.new(user: user)
    end

    def build
      return Result.new(relation: Topic.none, warnings: []) if @ast.nil?

      relation = apply_node(@ast, Topic.all)
      Result.new(relation: relation, warnings: @warnings)
    end

    private

    def apply_node(node, relation)
      return relation if node.nil?

      case node[:type]
      when :and
        result = apply_and(node[:children], relation)
        node[:negated] ? negate_relation(result, relation) : result
      when :or
        result = apply_or(node[:children], relation)
        node[:negated] ? negate_relation(result, relation) : result
      when :selector
        apply_selector(node, relation)
      when :text
        apply_text_search(node, relation)
      else
        relation
      end
    end

    def negate_relation(inner_relation, outer_relation)
      # Exclude topics that match the inner relation
      outer_relation.where.not(id: inner_relation.select(:id))
    end

    def apply_and(children, relation)
      children.reduce(relation) { |rel, child| apply_node(child, rel) }
    end

    def apply_or(children, relation)
      return relation if children.empty?

      # Build separate queries for each child and combine with OR
      subqueries = children.map { |child| apply_node(child, Topic.all) }

      # Combine using UNION via topic IDs
      combined_ids = subqueries.map { |sq| sq.select(:id) }

      # Use SQL UNION for the subqueries
      if combined_ids.size == 1
        relation.where(id: combined_ids.first)
      else
        union_sql = combined_ids.map { |sq| "(#{sq.to_sql})" }.join(" UNION ")
        relation.where("topics.id IN (#{union_sql})")
      end
    end

    def apply_selector(node, relation)
      key = node[:key]
      value = node[:value]
      negated = node[:negated]
      quoted = node[:quoted]
      conditions = node[:conditions]

      result = case key
      when :from
                 apply_from_selector(value, relation, negated: negated, quoted: quoted, conditions: conditions)
      when :starter
                 apply_starter_selector(value, relation, negated: negated, quoted: quoted)
      when :last_from
                 apply_last_from_selector(value, relation, negated: negated, quoted: quoted)
      when :title
                 apply_title_selector(value, relation, negated: negated, quoted: quoted)
      when :body
                 apply_body_selector(value, relation, negated: negated, quoted: quoted)
      when :unread
                 apply_unread_selector(value, relation, negated: negated)
      when :read
                 apply_read_selector(value, relation, negated: negated)
      when :reading
                 apply_reading_selector(value, relation, negated: negated)
      when :new
                 apply_new_selector(value, relation, negated: negated)
      when :starred
                 apply_starred_selector(value, relation, negated: negated)
      when :notes
                 apply_notes_selector(value, relation, negated: negated)
      when :tag
                 apply_tag_selector(value, relation, negated: negated, conditions: conditions)
      when :has
                 apply_has_selector(value, relation, negated: negated, conditions: conditions)
      when :messages
                 apply_count_selector(:message_count, value, relation, negated: negated)
      when :participants
                 apply_count_selector(:participant_count, value, relation, negated: negated)
      when :contributors
                 apply_count_selector(:contributor_participant_count, value, relation, negated: negated)
      when :first_after
                 apply_date_selector(:created_at, :>=, value, relation, negated: negated)
      when :first_before
                 apply_date_selector(:created_at, :<, value, relation, negated: negated)
      when :messages_after
                 apply_messages_date_selector(:>=, value, relation, negated: negated)
      when :messages_before
                 apply_messages_date_selector(:<, value, relation, negated: negated)
      when :last_after
                 apply_last_date_selector(:>=, value, relation, negated: negated)
      when :last_before
                 apply_last_date_selector(:<, value, relation, negated: negated)
      when :commitfest
                 apply_commitfest_selector(value, relation, negated: negated, conditions: conditions)
      else
                 @warnings << "Unknown selector: #{key}"
                 relation
      end

      result || relation
    end

    def apply_text_search(node, relation)
      value = node[:value]
      negated = node[:negated]
      quoted = node[:quoted]

      return relation if value.blank?

      # Text search: check both title and body
      # Using FTS if available, falling back to ILIKE
      # Quoted text uses phrase matching (words must be adjacent)
      condition = build_text_search_condition(value, phrase: quoted)

      if negated
        relation.where.not(id: Topic.where(condition))
      else
        relation.where(condition)
      end
    end

    def build_text_search_condition(value, phrase: false)
      # Try to use FTS first, with ILIKE fallback
      # Check if title_tsv column exists
      if Topic.column_names.include?("title_tsv")
        # Use FTS - phraseto_tsquery for phrase matching, plainto_tsquery otherwise
        sanitized = sanitize_fts_query(value)
        tsquery_func = phrase ? "phraseto_tsquery" : "plainto_tsquery"
        title_fts = "topics.title_tsv @@ #{tsquery_func}('english', #{ActiveRecord::Base.connection.quote(sanitized)})"

        # Check if messages have body_tsv
        if Message.column_names.include?("body_tsv")
          body_topic_ids = Message.where(
            "body_tsv @@ #{tsquery_func}('english', ?)", sanitized
          ).select(:topic_id)
          Arel.sql("(#{title_fts} OR topics.id IN (#{body_topic_ids.to_sql}))")
        else
          # Fall back to ILIKE for body
          pattern = "%#{sanitize_like(value)}%"
          body_topic_ids = Message.where("body ILIKE ?", pattern).select(:topic_id)
          Arel.sql("(#{title_fts} OR topics.id IN (#{body_topic_ids.to_sql}))")
        end
      else
        # Fall back to ILIKE for both
        pattern = "%#{sanitize_like(value)}%"
        body_topic_ids = Message.where("body ILIKE ?", pattern).select(:topic_id)
        Arel.sql("(topics.title ILIKE #{ActiveRecord::Base.connection.quote(pattern)} OR topics.id IN (#{body_topic_ids.to_sql}))")
      end
    end

    # === Author Selectors ===

    def apply_from_selector(value, relation, negated:, quoted:, conditions: nil)
      result = @value_resolver.resolve_author(value, quoted: quoted)
      @warnings.concat(result.warnings)

      person_ids = result.person_ids
      return relation if person_ids.empty?

      if conditions.blank?
        # Original behavior - any message from these persons
        message_topic_ids = Message.where(sender_person_id: person_ids).select(:topic_id)
        return negated ? relation.where.not(id: message_topic_ids) : relation.where(id: message_topic_ids)
      end

      # With conditions: use topic_participants with conditions
      topic_ids = build_from_condition_query(person_ids, conditions)
      negated ? relation.where.not(id: topic_ids) : relation.where(id: topic_ids)
    end

    def build_from_condition_query(person_ids, conditions)
      # Separate conditions into participant-level and message-level
      participant_conditions = conditions.reject { |c| c[:key] == :body }
      message_conditions = conditions.select { |c| c[:key] == :body }

      # Start with topic_participants for the given persons
      base = TopicParticipant.where(person_id: person_ids)

      # Apply participant-level row conditions (dates, etc.)
      row_conditions = participant_conditions.reject { |c| c[:key] == :messages }
      agg_conditions = participant_conditions.select { |c| c[:key] == :messages }

      row_conditions.each { |cond| base = apply_participant_row_condition(base, cond) }

      # Handle message conditions (body:) - need subquery on messages
      if message_conditions.any?
        body_cond = message_conditions.first
        body_topic_ids = build_body_condition_subquery(person_ids, body_cond[:value], body_cond[:quoted])
        base = base.where(topic_id: body_topic_ids)
      end

      if person_ids.size == 1 && agg_conditions.any?
        # Single person: can use row-level message_count directly
        agg_conditions.each { |cond| base = apply_participant_row_condition(base, cond) }
        base.select(:topic_id)
      elsif agg_conditions.any?
        # Team: need GROUP BY with HAVING for combined message count
        grouped = base.group(:topic_id)
        agg_conditions.each do |cond|
          case cond[:key]
          when :messages
            op, num = parse_count_value(cond[:value])
            next unless num
            grouped = grouped.having("SUM(topic_participants.message_count) #{op} ?", num)
          end
        end
        grouped.select(:topic_id)
      else
        base.select(:topic_id)
      end
    end

    def apply_participant_row_condition(participants, condition)
      case condition[:key]
      when :messages
        op, num = parse_count_value(condition[:value])
        return participants unless num
        participants.where("topic_participants.message_count #{op} ?", num)
      when :last_before
        date = DateParser.new(condition[:value]).parse
        return participants unless date
        participants.where("topic_participants.last_message_at < ?", date)
      when :last_after
        date = DateParser.new(condition[:value]).parse
        return participants unless date
        participants.where("topic_participants.last_message_at >= ?", date)
      when :first_before
        date = DateParser.new(condition[:value]).parse
        return participants unless date
        participants.where("topic_participants.first_message_at < ?", date)
      when :first_after
        date = DateParser.new(condition[:value]).parse
        return participants unless date
        participants.where("topic_participants.first_message_at >= ?", date)
      else
        participants
      end
    end

    def build_body_condition_subquery(person_ids, body_value, quoted)
      # Find topics where any of the persons posted a message matching body
      if Message.column_names.include?("body_tsv")
        sanitized = sanitize_fts_query(body_value)
        tsquery_func = quoted ? "phraseto_tsquery" : "plainto_tsquery"
        Message.where(sender_person_id: person_ids)
               .where("body_tsv @@ #{tsquery_func}('english', ?)", sanitized)
               .select(:topic_id)
      else
        pattern = "%#{sanitize_like(body_value)}%"
        Message.where(sender_person_id: person_ids)
               .where("body ILIKE ?", pattern)
               .select(:topic_id)
      end
    end

    def apply_starter_selector(value, relation, negated:, quoted:)
      result = @value_resolver.resolve_author(value, quoted: quoted)
      @warnings.concat(result.warnings)

      person_ids = result.person_ids
      return relation if person_ids.empty?

      if negated
        relation.where.not(creator_person_id: person_ids)
      else
        relation.where(creator_person_id: person_ids)
      end
    end

    def apply_last_from_selector(value, relation, negated:, quoted:)
      result = @value_resolver.resolve_author(value, quoted: quoted)
      @warnings.concat(result.warnings)

      person_ids = result.person_ids
      return relation if person_ids.empty?

      if negated
        relation.where.not(last_sender_person_id: person_ids)
      else
        relation.where(last_sender_person_id: person_ids)
      end
    end

    # === Content Selectors ===

    def apply_title_selector(value, relation, negated:, quoted: false)
      return relation if value.blank?

      condition = if Topic.column_names.include?("title_tsv")
        sanitized = sanitize_fts_query(value)
        # Use phraseto_tsquery for quoted values (phrase matching), plainto_tsquery otherwise
        tsquery_func = quoted ? "phraseto_tsquery" : "plainto_tsquery"
        [ "topics.title_tsv @@ #{tsquery_func}('english', ?)", sanitized ]
      else
        pattern = "%#{sanitize_like(value)}%"
        [ "topics.title ILIKE ?", pattern ]
      end

      if negated
        relation.where.not(*condition)
      else
        relation.where(*condition)
      end
    end

    def apply_body_selector(value, relation, negated:, quoted: false)
      return relation if value.blank?

      message_topic_ids = if Message.column_names.include?("body_tsv")
        sanitized = sanitize_fts_query(value)
        # Use phraseto_tsquery for quoted values (phrase matching), plainto_tsquery otherwise
        tsquery_func = quoted ? "phraseto_tsquery" : "plainto_tsquery"
        Message.where("body_tsv @@ #{tsquery_func}('english', ?)", sanitized).select(:topic_id)
      else
        pattern = "%#{sanitize_like(value)}%"
        Message.where("body ILIKE ?", pattern).select(:topic_id)
      end

      if negated
        relation.where.not(id: message_topic_ids)
      else
        relation.where(id: message_topic_ids)
      end
    end

    # === State Selectors ===

    def apply_unread_selector(value, relation, negated:)
      result = @value_resolver.resolve_state_subject(value)
      @warnings.concat(result.warnings)

      user_ids = result.user_ids
      return relation if user_ids.empty?

      # Topics where any of these users have unread messages
      # A topic is unread if max_message_id > max_read_range_end
      if user_ids.size == 1
        apply_unread_for_user(user_ids.first, relation, negated: negated)
      else
        apply_unread_for_users(user_ids, relation, negated: negated)
      end
    end

    def apply_unread_for_user(user_id, relation, negated:)
      # Unread: last message id > max read range end
      sql = <<~SQL.squish
        topics.id IN (
          SELECT t.id FROM topics t
          LEFT JOIN message_read_ranges mrr ON mrr.topic_id = t.id AND mrr.user_id = #{user_id.to_i}
          GROUP BY t.id
          HAVING t.last_message_id > COALESCE(MAX(mrr.range_end_message_id), 0)
        )
      SQL

      if negated
        relation.where.not(Arel.sql(sql))
      else
        relation.where(Arel.sql(sql))
      end
    end

    def apply_unread_for_users(user_ids, relation, negated:)
      # For team: topic is unread if NO team member has fully read
      sanitized_ids = user_ids.map(&:to_i).join(",")
      fully_read_sql = <<~SQL.squish
        SELECT DISTINCT mrr.topic_id FROM message_read_ranges mrr
        JOIN topics t ON t.id = mrr.topic_id
        WHERE mrr.user_id IN (#{sanitized_ids})
        GROUP BY mrr.topic_id, t.last_message_id
        HAVING MAX(mrr.range_end_message_id) >= t.last_message_id
      SQL

      if negated
        # Negated unread = fully read by at least one team member
        relation.where(Arel.sql("topics.id IN (#{fully_read_sql})"))
      else
        # Unread = not fully read by any team member
        relation.where(Arel.sql("topics.id NOT IN (#{fully_read_sql})"))
      end
    end

    def apply_read_selector(value, relation, negated:)
      result = @value_resolver.resolve_state_subject(value)
      @warnings.concat(result.warnings)

      user_ids = result.user_ids
      return relation if user_ids.empty?

      # Topics that are fully read
      if user_ids.size == 1
        apply_read_for_user(user_ids.first, relation, negated: negated)
      else
        apply_read_for_users(user_ids, relation, negated: negated)
      end
    end

    def apply_read_for_user(user_id, relation, negated:)
      sql = <<~SQL.squish
        topics.id IN (
          SELECT t.id FROM topics t
          JOIN message_read_ranges mrr ON mrr.topic_id = t.id AND mrr.user_id = #{user_id.to_i}
          GROUP BY t.id
          HAVING MAX(mrr.range_end_message_id) >= t.last_message_id
        )
      SQL

      if negated
        relation.where.not(Arel.sql(sql))
      else
        relation.where(Arel.sql(sql))
      end
    end

    def apply_read_for_users(user_ids, relation, negated:)
      sanitized_ids = user_ids.map(&:to_i).join(",")
      sql = <<~SQL.squish
        topics.id IN (
          SELECT mrr.topic_id FROM message_read_ranges mrr
          JOIN topics t ON t.id = mrr.topic_id
          WHERE mrr.user_id IN (#{sanitized_ids})
          GROUP BY mrr.topic_id, t.last_message_id
          HAVING MAX(mrr.range_end_message_id) >= t.last_message_id
        )
      SQL

      if negated
        relation.where.not(Arel.sql(sql))
      else
        relation.where(Arel.sql(sql))
      end
    end

    def apply_reading_selector(value, relation, negated:)
      result = @value_resolver.resolve_state_subject(value)
      @warnings.concat(result.warnings)

      user_ids = result.user_ids
      return relation if user_ids.empty?

      # Topics partially read (some read, but not all)
      sanitized_ids = user_ids.map(&:to_i).join(",")
      sql = <<~SQL.squish
        topics.id IN (
          SELECT mrr.topic_id FROM message_read_ranges mrr
          JOIN topics t ON t.id = mrr.topic_id
          WHERE mrr.user_id IN (#{sanitized_ids})
          GROUP BY mrr.topic_id, t.last_message_id
          HAVING MAX(mrr.range_end_message_id) > 0
            AND MAX(mrr.range_end_message_id) < t.last_message_id
        )
      SQL

      if negated
        relation.where.not(Arel.sql(sql))
      else
        relation.where(Arel.sql(sql))
      end
    end

    def apply_new_selector(value, relation, negated:)
      result = @value_resolver.resolve_state_subject(value)
      @warnings.concat(result.warnings)

      user_ids = result.user_ids
      return relation if user_ids.empty?

      # New: never seen (no awareness, no read ranges, after user's aware_before)
      if user_ids.size == 1
        apply_new_for_user(user_ids.first, relation, negated: negated)
      else
        # For team, new = no team member has any awareness
        apply_new_for_users(user_ids, relation, negated: negated)
      end
    end

    def apply_new_for_user(user_id, relation, negated:)
      user = User.find_by(id: user_id)
      aware_before = user&.aware_before

      sql = if aware_before
        aware_before_sql = ActiveRecord::Base.connection.quote(aware_before)
        <<~SQL.squish
          topics.id IN (
            SELECT t.id FROM topics t
            LEFT JOIN thread_awareness ta ON ta.topic_id = t.id AND ta.user_id = #{user_id.to_i}
            LEFT JOIN message_read_ranges mrr ON mrr.topic_id = t.id AND mrr.user_id = #{user_id.to_i}
            WHERE ta.aware_until_message_id IS NULL
            GROUP BY t.id
            HAVING COALESCE(MAX(mrr.range_end_message_id), 0) = 0
              AND t.last_message_at > #{aware_before_sql}
          )
        SQL
      else
        <<~SQL.squish
          topics.id IN (
            SELECT t.id FROM topics t
            LEFT JOIN thread_awareness ta ON ta.topic_id = t.id AND ta.user_id = #{user_id.to_i}
            LEFT JOIN message_read_ranges mrr ON mrr.topic_id = t.id AND mrr.user_id = #{user_id.to_i}
            WHERE ta.aware_until_message_id IS NULL
            GROUP BY t.id
            HAVING COALESCE(MAX(mrr.range_end_message_id), 0) = 0
          )
        SQL
      end

      if negated
        relation.where.not(Arel.sql(sql))
      else
        relation.where(Arel.sql(sql))
      end
    end

    def apply_new_for_users(user_ids, relation, negated:)
      sanitized_ids = user_ids.map(&:to_i).join(",")
      # For team: topic is new if NO team member has any awareness or reads
      seen_sql = <<~SQL.squish
        SELECT DISTINCT topic_id FROM thread_awareness WHERE user_id IN (#{sanitized_ids})
        UNION
        SELECT DISTINCT topic_id FROM message_read_ranges WHERE user_id IN (#{sanitized_ids})
      SQL

      if negated
        # Negated new = someone has seen it
        relation.where(Arel.sql("topics.id IN (#{seen_sql})"))
      else
        # New = nobody has seen it
        relation.where(Arel.sql("topics.id NOT IN (#{seen_sql})"))
      end
    end

    def apply_starred_selector(value, relation, negated:)
      result = @value_resolver.resolve_state_subject(value)
      @warnings.concat(result.warnings)

      user_ids = result.user_ids
      return relation if user_ids.empty?

      starred_topic_ids = TopicStar.where(user_id: user_ids).select(:topic_id)

      if negated
        relation.where.not(id: starred_topic_ids)
      else
        relation.where(id: starred_topic_ids)
      end
    end

    def apply_notes_selector(value, relation, negated:)
      result = @value_resolver.resolve_state_subject(value)
      @warnings.concat(result.warnings)

      user_ids = result.user_ids
      return relation if user_ids.empty?

      note_topic_ids = Note.where(author_id: user_ids, deleted_at: nil).select(:topic_id)

      if negated
        relation.where.not(id: note_topic_ids)
      else
        relation.where(id: note_topic_ids)
      end
    end

    def apply_tag_selector(value, relation, negated:, conditions: nil)
      # Use bracket syntax handling for all tag queries
      apply_tag_with_conditions(value, relation, negated: negated, conditions: conditions || [])
    end

    def apply_tag_with_conditions(tag_name, relation, negated:, conditions:)
      unless @user
        @warnings << "Must be signed in to search by tags"
        return relation.none
      end

      # Start with notes visible to the current user
      notes = Note.active.visible_to(@user).joins(:note_tags)

      # Filter by tag name if provided
      if tag_name.present?
        notes = notes.where("LOWER(note_tags.tag) = LOWER(?)", tag_name)
      end

      # Apply conditions
      from_cond = conditions.find { |c| c[:key] == :from }
      added_before_cond = conditions.find { |c| c[:key] == :added_before }
      added_after_cond = conditions.find { |c| c[:key] == :added_after }

      # Apply from: condition
      if from_cond
        from_value = from_cond[:value]
        if from_value == "me"
          notes = notes.where(author_id: @user.id)
        else
          # Try to resolve as team or username
          team = Team.joins(:team_members)
                     .where(team_members: { user_id: @user.id })
                     .find_by("LOWER(teams.name) = LOWER(?)", from_value)
          if team
            user_ids = TeamMember.where(team_id: team.id).pluck(:user_id)
            notes = notes.where(author_id: user_ids)
          else
            user = User.find_by("LOWER(username) = LOWER(?)", from_value)
            if user
              notes = notes.where(author_id: user.id)
            else
              @warnings << "Unknown source '#{from_value}' for tag condition"
              return relation
            end
          end
        end
      end

      # Apply added_before: condition (note creation time)
      if added_before_cond
        date = DateParser.new(added_before_cond[:value]).parse
        notes = notes.where("notes.created_at < ?", date) if date
      end

      # Apply added_after: condition (note creation time)
      if added_after_cond
        date = DateParser.new(added_after_cond[:value]).parse
        notes = notes.where("notes.created_at >= ?", date) if date
      end

      tagged_topic_ids = notes.select(:topic_id).distinct

      if negated
        relation.where.not(id: tagged_topic_ids)
      else
        relation.where(id: tagged_topic_ids)
      end
    end

    # === Presence Selectors ===

    def apply_has_selector(value, relation, negated:, conditions: nil)
      normalized = value.to_s.downcase

      # Handle conditions for attachment and patch
      if conditions.present? && %w[attachment patch].include?(normalized)
        topic_ids = build_has_condition_query(normalized, conditions)
        return negated ? relation.where.not(id: topic_ids) : relation.where(id: topic_ids)
      end

      case normalized
      when "attachment"
        topic_ids_subquery = Attachment.joins(:message).select("messages.topic_id").distinct
        negated ? relation.where.not(id: topic_ids_subquery) : relation.where(id: topic_ids_subquery)
      when "patch"
        topic_ids_subquery = Attachment.joins(:message)
          .where("attachments.file_name ILIKE ? OR attachments.file_name ILIKE ?", "%.patch", "%.diff")
          .select("messages.topic_id").distinct
        negated ? relation.where.not(id: topic_ids_subquery) : relation.where(id: topic_ids_subquery)
      when "contributor"
        # Use denormalized count
        if negated
          relation.where("topics.contributor_participant_count = 0")
        else
          relation.where("topics.contributor_participant_count > 0")
        end
      when "committer"
        committer_person_ids = ContributorMembership.where(contributor_type: "committer").select(:person_id)
        topic_ids_subquery = TopicParticipant.where(person_id: committer_person_ids).select(:topic_id).distinct
        negated ? relation.where.not(id: topic_ids_subquery) : relation.where(id: topic_ids_subquery)
      when "core_team"
        core_person_ids = ContributorMembership.where(contributor_type: "core_team").select(:person_id)
        topic_ids_subquery = TopicParticipant.where(person_id: core_person_ids).select(:topic_id).distinct
        negated ? relation.where.not(id: topic_ids_subquery) : relation.where(id: topic_ids_subquery)
      else
        @warnings << "Unknown has: value '#{value}'"
        relation
      end
    end

    def build_has_condition_query(has_type, conditions)
      # Start with attachments joined to messages
      base = Attachment.joins(:message)

      # For patches, filter by file extension
      if has_type == "patch"
        base = base.where("attachments.file_name ILIKE ? OR attachments.file_name ILIKE ?", "%.patch", "%.diff")
      end

      # Extract conditions
      from_cond = conditions.find { |c| c[:key] == :from }
      count_cond = conditions.find { |c| c[:key] == :count }
      name_cond = conditions.find { |c| c[:key] == :name }

      # Apply from: condition
      if from_cond
        result = @value_resolver.resolve_author(from_cond[:value], quoted: from_cond[:quoted])
        @warnings.concat(result.warnings)
        if result.person_ids.any?
          base = base.where(messages: { sender_person_id: result.person_ids })
        end
      end

      # Apply name: condition
      if name_cond
        pattern = "%#{sanitize_like(name_cond[:value])}%"
        base = base.where("attachments.file_name ILIKE ?", pattern)
      end

      # Apply count: condition - requires grouping
      if count_cond
        op, num = parse_count_value(count_cond[:value])
        if num
          base.group("messages.topic_id")
              .having("COUNT(*) #{op} ?", num)
              .select("messages.topic_id")
        else
          base.select("messages.topic_id").distinct
        end
      else
        base.select("messages.topic_id").distinct
      end
    end

    # === Count Selectors ===

    def apply_count_selector(column, value, relation, negated:)
      unless ALLOWED_COUNT_COLUMNS.include?(column)
        @warnings << "Invalid count column: #{column}"
        return relation
      end

      operator, number = parse_count_value(value)
      return relation unless number

      condition = case operator
      when ">" then [ "topics.#{column} > ?", number ]
      when "<" then [ "topics.#{column} < ?", number ]
      when ">=" then [ "topics.#{column} >= ?", number ]
      when "<=" then [ "topics.#{column} <= ?", number ]
      else [ "topics.#{column} = ?", number ]
      end

      if negated
        relation.where.not(*condition)
      else
        relation.where(*condition)
      end
    end

    def parse_count_value(value)
      match = value.to_s.match(/\A(>=|<=|>|<)?(\d+)\z/)
      return [ nil, nil ] unless match

      [ match[1] || "=", match[2].to_i ]
    end

    # === Date Selectors ===

    def apply_date_selector(column, operator, value, relation, negated:)
      unless ALLOWED_DATE_COLUMNS.include?(column)
        @warnings << "Invalid date column: #{column}"
        return relation
      end

      date = DateParser.new(value).parse
      return relation unless date

      # For negation, flip the operator
      actual_operator = if negated
        case operator
        when :>= then :<
        when :< then :>=
        when :> then :<=
        when :<= then :>
        else operator
        end
      else
        operator
      end

      relation.where("topics.#{column} #{actual_operator} ?", date)
    end

    def apply_messages_date_selector(operator, value, relation, negated:)
      date = DateParser.new(value).parse
      return relation unless date

      actual_operator = if negated
        case operator
        when :>= then :<
        when :< then :>=
        else operator
        end
      else
        operator
      end

      message_topic_ids = Message.where("messages.created_at #{actual_operator} ?", date).select(:topic_id)
      relation.where(id: message_topic_ids)
    end

    def apply_last_date_selector(operator, value, relation, negated:)
      date = DateParser.new(value).parse
      return relation unless date

      actual_operator = if negated
        case operator
        when :>= then :<
        when :< then :>=
        else operator
        end
      else
        operator
      end

      # Use the denormalized last_message_at column
      relation.where("topics.last_message_at #{actual_operator} ?", date)
    end

    def apply_commitfest_selector(value, relation, negated:, conditions:)
      relation = relation.left_joins(
        commitfest_patch_topics: {
          commitfest_patch: [
            :commitfest_tags,
            { commitfest_patch_commitfests: :commitfest }
          ]
        }
      )

      if value.present?
        if negated
          relation = relation.where.not(commitfest: { name: value })
        else
          relation = relation.where(commitfest: { name: value })
        end
      end

      apply_commitfest_with_conditions(relation, negated: negated, conditions: conditions || [])
    end

    def apply_commitfest_with_conditions(relation, negated:, conditions:)
      conditions.each do |condition|
        value = condition[:value]

        relation = case condition[:key]
        when :name
          column = Commitfest.arel_table[:name]
          apply_commitfest_filter(relation, column, value, negated:)
        when :status
          column = CommitfestPatchCommitfest.arel_table[:status]
          apply_commitfest_filter(relation, column, value, negated:)
        when :tag
          column = CommitfestTag.arel_table[:name]
          apply_commitfest_filter(relation, column, value, negated:)
        end
      end

      relation
    end

    def apply_commitfest_filter(relation, column, value, negated:)
      predicate = column.lower.eq(value.downcase)
      predicate = predicate.not if negated
      relation.where(predicate)
    end

    # === Helpers ===

    def sanitize_like(value)
      ActiveRecord::Base.sanitize_sql_like(value.to_s)
    end

    def sanitize_fts_query(value)
      # plainto_tsquery and phraseto_tsquery handle text-to-tsquery conversion
      # natively, so no operator injection is needed or desired.
      value.to_s.strip
    end
  end
end
