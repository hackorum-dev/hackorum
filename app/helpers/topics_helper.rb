module TopicsHelper
  # Replaces app/views/topics/_participant_row.html.slim
  def participant_row_html(participant:, avatar_size: 40, tooltip: nil)
    alias_record = participant[:alias]
    return nil unless alias_record

    person = participant[:person] || alias_record.person
    message_count = participant[:message_count]
    last_at = participant[:last_at]

    tooltip_parts = []
    tooltip_parts << pluralize(message_count, "message") if message_count
    tooltip_parts << "last #{smart_time_display(last_at)}" if last_at
    role_label = person&.contributor_badge
    tooltip_parts << role_label if role_label
    tooltip = tooltip || (tooltip_parts.any? ? tooltip_parts.join(", ") : alias_record.name)

    avatar_classes = [ "participant-avatar" ]

    membership_icons = []
    membership_types = person&.contributor_membership_types || []
    membership_icons << { icon: "fa-solid fa-people-group", label: "Core Team" } if membership_types.include?("core_team")
    membership_icons << { icon: "fa-solid fa-code-branch", label: "Committer" } if membership_types.include?("committer")
    membership_icons << { icon: "fa-solid fa-star", label: "Major Contributor" } if membership_types.include?("major_contributor")
    membership_icons << { icon: "fa-solid fa-award", label: "Significant Contributor" } if membership_types.include?("significant_contributor")
    if membership_types.include?("past_major_contributor") || membership_types.include?("past_significant_contributor")
      membership_icons << { icon: "fa-solid fa-clock-rotate-left", label: "Past Contributor" }
    end

    name_classes = [ "participant-name-link" ]
    name_classes << "is-committer" if membership_types.include?("committer")

    left = tag.div(class: "participant-left") do
      link_to(person_path(alias_record.email), class: "participant-avatar-link") do
        image_tag(alias_record.gravatar_url(size: avatar_size), class: avatar_classes.join(" "), alt: alias_record.name, title: tooltip)
      end +
      tag.div(class: "participant-details") do
        tag.div(class: "participant-name") do
          link_to(alias_record.name, person_path(alias_record.email), class: name_classes.join(" "), title: tooltip)
        end
      end
    end

    memberships = if membership_icons.any?
      tag.div(class: "participant-memberships") do
        safe_join(membership_icons.map { |entry|
          tag.span(class: "participant-icon", title: entry[:label]) do
            tag.i(class: entry[:icon])
          end
        })
      end
    end

    tag.div(class: "participant-row", title: tooltip) do
      safe_join([ left, memberships ].compact)
    end
  end

  # Replaces app/views/topics/_avatar_list.slim
  def avatar_list_html(participants:, total_participants:)
    avatars = tag.div(class: "participants-avatars") do
      avatar_tags = participants.filter_map do |participant|
        alias_record = participant[:alias] || participant
        next unless alias_record

        person = participant[:person] || alias_record.person
        message_count = participant[:message_count]
        last_at = participant[:last_at]

        tooltip_parts = [ alias_record.name ]
        tooltip_parts << pluralize(message_count, "message") if message_count
        tooltip_parts << "last #{smart_time_display(last_at)}" if last_at
        role_label = person&.contributor_badge
        tooltip_parts << role_label if role_label
        badge_text = tooltip_parts.join(", ")

        css_classes = [ "participant-avatar" ]
        css_classes << "is-core-team" if person&.core_team?
        css_classes << "is-committer" if !person&.core_team? && person&.committer?
        css_classes << "is-major-contributor" if !person&.core_team? && !person&.committer? && person&.major_contributor?
        css_classes << "is-significant-contributor" if !person&.core_team? && !person&.committer? && !person&.major_contributor? && person&.significant_contributor?
        css_classes << "is-past-contributor" if person&.past_contributor?

        link_to(person_path(alias_record.email), class: "participant-avatar-link") do
          image_tag(alias_record.gravatar_url(size: 32), class: css_classes.join(" "), alt: alias_record.name, title: badge_text)
        end
      end

      overflow = if total_participants > participants.count
        tag.span("+#{total_participants - participants.count}", class: "participants-count")
      end

      safe_join(avatar_tags) + (overflow || "".html_safe)
    end

    tag.div(class: "participants") { avatars }
  end

  # Replaces app/views/topics/_note_icon.html.slim
  def note_icon_html(topic:, count:)
    count = count.to_i
    classes = [ "topic-icon", "activity-note" ]
    classes << "is-hidden" unless count.positive?
    tooltip_label = count.positive? ? "Notes: #{count}" : "Notes"

    tag.div(
      class: classes.join(" "),
      id: dom_id(topic, "notes"),
      title: tooltip_label,
      data: { controller: "hover-popover", hover_popover_delay_value: "200", action: "mouseenter->hover-popover#show mouseleave->hover-popover#scheduleHide" }
    ) do
      icon = tag.i(class: "fa-solid fa-note-sticky")
      badge = count.positive? ? tag.span(count, class: "topic-icon-badge") : nil
      safe_join([ icon, badge ].compact)
    end
  end

  # Replaces app/views/topics/_star_icon.html.slim
  def star_icon_html(topic:, star_data:)
    star_data = star_data || {}
    starred_by_me = star_data[:starred_by_me] || false
    team_starrers = star_data[:team_starrers] || []
    total_count = (starred_by_me ? 1 : 0) + team_starrers.size

    classes = [ "topic-icon", "activity-star" ]
    classes << "is-hidden" if total_count.zero?
    classes << "is-starred" if starred_by_me
    icon_class = starred_by_me ? "fa-solid fa-star" : "fa-regular fa-star"

    tag.div(
      class: classes.join(" "),
      id: dom_id(topic, "stars"),
      data: { controller: "hover-popover", hover_popover_delay_value: "200", action: "mouseenter->hover-popover#show mouseleave->hover-popover#scheduleHide" }
    ) do
      parts = [ tag.i(class: icon_class) ]
      parts << tag.span(total_count, class: "topic-icon-badge") if total_count > 2

      if starred_by_me || team_starrers.any?
        hover_rows = []
        if starred_by_me
          my_alias = current_user.person&.default_alias || current_user.aliases&.first
          if my_alias
            participant_stub = { alias: my_alias }
            role_label = my_alias.contributor_badge || "User"
            hover_rows << participant_row_html(participant: participant_stub, avatar_size: 32, tooltip: "#{my_alias.name} (#{role_label})")
          end
        end
        team_starrers.each do |alias_record|
          participant_stub = { alias: alias_record }
          role_label = alias_record.contributor_badge || "User"
          hover_rows << participant_row_html(participant: participant_stub, avatar_size: 32, tooltip: "#{alias_record.name} (#{role_label})")
        end
        parts << tag.div(
          class: "topic-icon-hover",
          data: { hover_popover_target: "popover", action: "mouseenter->hover-popover#show mouseleave->hover-popover#scheduleHide" }
        ) { safe_join(hover_rows.compact) }
      end

      safe_join(parts)
    end
  end

  # Replaces app/views/topics/_participation_icon.html.slim
  def participation_icon_html(topic:, participation:)
    participation = participation || {}
    classes = [ "topic-icon", "activity-team" ]
    classes << "is-mine" if participation[:mine]
    classes << "is-hidden" unless participation[:mine] || participation[:team]
    aliases = participation[:aliases] || []
    count = aliases.size

    tag.div(
      class: classes.join(" "),
      id: dom_id(topic, "participation"),
      data: { controller: "hover-popover", hover_popover_delay_value: "200", action: "mouseenter->hover-popover#show mouseleave->hover-popover#scheduleHide" }
    ) do
      parts = [ tag.i(class: "fa-solid fa-user-group") ]
      parts << tag.span(count, class: "topic-icon-badge") if count > 1

      if aliases.any?
        hover_rows = aliases.map do |alias_record|
          participant_stub = { alias: alias_record }
          role_label = alias_record.contributor_badge || "User"
          participant_row_html(participant: participant_stub, avatar_size: 32, tooltip: "#{alias_record.name} (#{role_label})")
        end
        parts << tag.div(
          class: "topic-icon-hover",
          data: { hover_popover_target: "popover", action: "mouseenter->hover-popover#show mouseleave->hover-popover#scheduleHide" }
        ) { safe_join(hover_rows.compact) }
      end

      safe_join(parts)
    end
  end

  # Replaces app/views/topics/_team_readers_icon.html.slim
  def team_readers_icon_html(topic:, readers:)
    count = readers&.size.to_i
    classes = [ "topic-icon", "activity-team-read" ]
    classes << "is-hidden" if count.zero?

    tag.div(
      class: classes.join(" "),
      id: dom_id(topic, "team_readers"),
      data: { controller: "hover-popover", hover_popover_delay_value: "200", action: "mouseenter->hover-popover#show mouseleave->hover-popover#scheduleHide" }
    ) do
      parts = [ tag.i(class: "fa-solid fa-users") ]

      if count.positive?
        parts << tag.span(count, class: "topic-icon-badge")

        hover_rows = readers.filter_map do |reader|
          alias_record = reader[:user]&.person&.default_alias || reader[:user]&.aliases&.first
          next unless alias_record

          participant_stub = { alias: alias_record }
          role_label = alias_record.contributor_badge || "User"
          participant_row_html(participant: participant_stub, avatar_size: 32, tooltip: "#{alias_record.name} (#{reader[:status]}, #{role_label})")
        end
        parts << tag.div(
          class: "topic-icon-hover",
          data: { hover_popover_target: "popover", action: "mouseenter->hover-popover#show mouseleave->hover-popover#scheduleHide" }
        ) { safe_join(hover_rows) }
      end

      safe_join(parts)
    end
  end

  def topic_title_link(topic)
    if user_signed_in? && current_user.open_threads_at_first_unread?
      topic_path(topic, anchor: "first-unread")
    else
      topic_path(topic)
    end
  end

  def topic_filter_labels
    {
      "no_contrib_replies"   => "No contributor/committer replies",
      "patch_no_replies"     => "Patch, no replies",
      "reading_incomplete"   => "Reading in progress",
      "new_for_me"           => "New for me",
      "started_by_me"        => "Started by me",
      "messaged_by_me"       => "I posted here",
      "starred_by_me"        => "Starred by me",
      "starred_by_team"      => "Starred by team",
      "team_unread"          => "Not yet read by team",
      "team_reading_others"  => "Teammates reading",
      "team_reading_any"     => "Team reading",
      "team_started"         => "Started by team",
      "team_messaged"        => "Team messages"
    }
  end
end
