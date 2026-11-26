require "digest"
require "fileutils"
require "json"

module Classify
  # prompt.md for codex on stdin; groups.tsv catalog; messages/NNN.txt only in digest mode
  class BundleWriter
    PROMPT_PATH = Rails.root.join("config/classify/prompt.md")
    SCHEMA_PATH = Rails.root.join("config/classify/result.schema.json")
    MESSAGE_CHAR_CAP = 12_000
    INLINE_CHAR_LIMIT = 160_000
    DIGEST_LAST = 20
    DIGEST_SLACK = 1_000
    GAP_LINE_MAX = 80
    LIST_CAP = 30
    PATH_LIST_MAX = 20
    TOP_DIRS = 8
    SUMMARY_CAP = 400
    PLACEHOLDER_RE = /\{\{(\w+)\}\}/
    MEMBERSHIP_SOURCES = { "seed" => "suggested by the automatic first pass", "llm" => "set by an earlier run",
                           "human" => "set by an admin" }.freeze

    def self.prompt_version
      Digest::SHA256.hexdigest(File.read(PROMPT_PATH) + File.read(SCHEMA_PATH))[0, 12]
    end

    def initialize(topic:, previous: nil)
      @topic = topic
      @previous = previous
    end

    def write(dir)
      FileUtils.mkdir_p(dir)
      messages = @topic.messages.includes(:sender, sender_person: :default_alias).order(:created_at, :id).to_a
      @committers = committer_ids(messages)
      bodies = messages.map { |m| MessageBodyText.strip_quotes(m.body).strip }
      blocks = messages.each_with_index.map { |m, i| block(m, i + 1, bodies[i]) }
      mode, thread = thread_section(blocks, messages)
      write_message_files(dir, messages, bodies) if mode == "digest"
      write_catalog(dir)
      groups = CandidateGroups.new(@topic).call
      values = { "topic_id" => @topic.id.to_s, "title" => @topic.title.to_s, "facts" => facts(messages),
                 "groups" => groups_text(groups), "previous" => previous_text, "thread" => thread }
      prompt = File.read(PROMPT_PATH).gsub(PLACEHOLDER_RE) { values.fetch(Regexp.last_match(1)) }
      File.write(File.join(dir, "prompt.md"), prompt)
      index = { "mode" => mode, "message_count" => messages.size, "through_message_id" => messages.last&.id,
                "candidate_group_ids" => groups.map(&:id) }
      File.write(File.join(dir, "index.json"), JSON.pretty_generate(index))
      index
    end

    private

    def write_catalog(dir)
      counts = FeatureGroupTopic.group(:feature_group_id).count
      rows = FeatureGroup.live.order(:name, :id).map do |g|
        [ g.id, g.name.to_s.squish, counts.fetch(g.id, 0), g.summary.to_s.squish ].join("\t")
      end
      File.write(File.join(dir, "groups.tsv"), ([ "id\tname\tthreads\tsummary" ] + rows).join("\n") + "\n")
    end

    def committer_ids(messages)
      ContributorMembership.where(contributor_type: "committer", person_id: messages.map(&:sender_person_id).uniq)
                           .pluck(:person_id).to_set
    end

    def ordinal(n) = format("%03d", n)

    def header(m, n)
      flags = (@committers.include?(m.sender_person_id) ? "(committer)" : "") + (m.is_patch_submission ? "(patch)" : "")
      [ "### [#{ordinal(n)}]", day(m.created_at), m.sender_display_alias&.name || "unknown",
        flags.presence ].compact.join(" ")
    end

    def block(m, n, body)
      body = "#{body[0, MESSAGE_CHAR_CAP]}\n[... cut #{body.size - MESSAGE_CHAR_CAP} chars]" if body.size > MESSAGE_CHAR_CAP
      "#{header(m, n)}\n\n#{body}\n"
    end

    def thread_section(blocks, messages)
      inline = "#{count(blocks.size, 'message')}, all shown, oldest first.\n\n#{blocks.join("\n")}"
      return [ "inline", inline ] if inline.size <= INLINE_CHAR_LIMIT

      [ "digest", digest(blocks, messages) ]
    end

    # first, newest DIGEST_LAST, then committers newest first, while they fit
    def digest(blocks, messages)
      n = blocks.size
      committer_idx = (0...n).select { |i| @committers.include?(messages[i].sender_person_id) }
      order = ([ 0 ] + (0...n).to_a.last(DIGEST_LAST).reverse + committer_idx.reverse).uniq
      budget = INLINE_CHAR_LIMIT - DIGEST_SLACK
      chosen = []
      order.each do |i|
        cost = blocks[i].size + 1 + GAP_LINE_MAX
        next if cost > budget

        chosen << i
        budget -= cost
      end
      parts = []
      last = -1
      chosen.sort.each do |i|
        parts << gap(last + 1, i - 1) if i > last + 1
        parts << blocks[i]
        last = i
      end
      parts << gap(last + 1, n - 1) if last < n - 1
      "#{digest_intro(n, chosen.size)}\n\n#{parts.join("\n")}"
    end

    def digest_intro(total, shown)
      "This thread is long: #{total} messages, #{shown} of them shown here (the first message, the latest " \
        "ones and messages by committers, as space allows; gaps are marked). Every message, uncut, is in the " \
        "working directory as messages/NNN.txt (NNN is the message number, e.g. messages/001.txt). Read or grep " \
        "those files when the messages shown are not enough."
    end

    def gap(from, to)
      return "[... message [#{ordinal(from + 1)}] not shown ...]\n" if from == to

      "[... #{to - from + 1} messages, [#{ordinal(from + 1)}] to [#{ordinal(to + 1)}], not shown ...]\n"
    end

    def write_message_files(dir, messages, bodies)
      mdir = File.join(dir, "messages")
      FileUtils.mkdir_p(mdir)
      messages.each_with_index do |m, i|
        File.write(File.join(mdir, "#{ordinal(i + 1)}.txt"),
                   "#{header(m, i + 1)}\nSubject: #{m.subject}\n\n#{bodies[i]}\n")
      end
    end

    def facts(messages)
      lines = [ "- Lists: #{@topic.mailing_lists.order(:identifier).pluck(:identifier).join(', ').presence || 'none'}" ]
      if messages.any?
        lines << "- Messages: #{messages.size} from #{count(messages.map(&:sender_person_id).uniq.size, 'sender')}, " \
                 "#{day(messages.first.created_at)} to #{day(messages.last.created_at)}"
      end
      lines.concat(commitfest_lines, patch_lines(messages), commit_lines, linked_thread_lines)
      lines << current_group_line
      lines.join("\n")
    end

    def day(time) = time.utc.strftime("%Y-%m-%d")

    def count(n, word) = "#{n} #{word.pluralize(n)}"

    def commitfest_lines
      patches = @topic.commitfest_patches.includes(:commitfest_tags).order(:id).to_a
      return [ "- Commitfest entries: none" ] if patches.empty?

      status = CommitfestPatchCommitfest.joins(:commitfest).where(commitfest_patch_id: patches.map(&:id))
                                        .order("commitfests.start_date DESC", "commitfest_patch_commitfests.id DESC")
                                        .pluck(:commitfest_patch_id, :status)
                                        .each_with_object({}) { |(id, s), h| h[id] ||= s }
      [ "- Commitfest entries:" ] + patches.map do |p|
        parts = [ ("topic: #{p.topic}" if p.topic.present?),
                  ("tags: #{p.commitfest_tags.map(&:name).join(', ')}" if p.commitfest_tags.any?),
                  "latest status: #{status[p.id] || 'unknown'}" ].compact
        "  - \"#{p.title}\" (#{parts.join('; ')})"
      end
    end

    def patch_lines(messages)
      ordinals = messages.each_with_index.to_h { |m, i| [ m.id, i + 1 ] }
      patch_msgs = messages.select(&:is_patch_submission)
      return [ "- Patch messages: none" ] if patch_msgs.empty?

      files = PatchSubmissionFile.where(message_id: patch_msgs.map(&:id)).pluck(:message_id, :path)
      file_counts = files.map(&:first).tally
      lines_by_msg = patch_msgs.to_h { |m| [ m.id, patch_stats(m.id) ] }
      describe = lambda do |m|
        s = lines_by_msg[m.id]
        in_files = file_counts[m.id] ? ", #{count(file_counts[m.id], 'file')}" : ""
        "[#{ordinal(ordinals[m.id])}] +#{s[:added]}/-#{s[:removed]} lines#{in_files}"
      end
      largest = patch_msgs.max_by { |m| lines_by_msg[m.id].values.sum }
      out = [ "- Patch messages: #{patch_msgs.size}; largest #{describe.(largest)}; latest #{describe.(patch_msgs.last)}" ]
      paths = files.map(&:last).uniq.sort
      return out if paths.empty?

      out << "- Files touched by the patches: #{paths.size}; top directories: #{top_dirs(paths)}"
      out << "  #{paths.join(', ')}" if paths.size <= PATH_LIST_MAX
      out
    end

    def patch_stats(message_id)
      Attachment.where(message_id:).reject(&:nocfbot?).each_with_object({ added: 0, removed: 0 }) do |a, sum|
        stats = a.diff_line_stats
        sum[:added] += stats[:added]
        sum[:removed] += stats[:removed]
      end
    end

    def top_dirs(paths)
      paths.map { |p| File.dirname(p).split("/").first(3).join("/").sub(/\A\.\z/, "(top level)") }
           .tally.sort_by { |d, c| [ -c, d ] }.first(TOP_DIRS).map { |d, c| "#{d} (#{c})" }.join(", ")
    end

    def commit_lines
      commits = Commit.where(id: CommitTopic.where(topic_id: @topic.id).select(:commit_id)).order(:committed_at, :id).to_a
      return [ "- Linked commits: none" ] if commits.empty?

      changes = commits.group_by { |c| c.cherry_picked_from_sha.presence || c.sha }
      lines = [ "- Linked commits (#{changes.size}):" ]
      changes.first(LIST_CAP).each do |sha, group|
        main = group.find { |c| c.sha == sha } || group.first
        branches = branch_label(group)
        lines << "  - #{main.sha[0, 10]} #{day(main.committed_at)} #{main.subject}#{" (#{branches})" if branches}"
      end
      lines << "  - ... #{changes.size - LIST_CAP} more" if changes.size > LIST_CAP
      lines
    end

    def branch_label(group)
      on_master = group.any? { |c| c.branches.include?("master") }
      stable = group.reject { |c| c.branches.include?("master") }.flat_map(&:branches).uniq.sort
      if on_master
        stable.any? ? "master, backpatched to #{stable.join(', ')}" : "master only"
      elsif stable.any?
        "stable branches only: #{stable.join(', ')}"
      end
    end

    def linked_thread_lines
      links = TopicLink.where(topic_id: @topic.id).to_a.group_by(&:other_topic_id)
      threads = Scope.topics.where(id: links.keys).to_a
                     .sort_by { |t| [ -(t.last_message_at || t.created_at).to_i, t.id ] }
      return [ "- Linked threads: none" ] if threads.empty?

      ids = threads.map(&:id)
      tags = BotNote.tags_by_topic(ids)
      groups = FeatureGroupTopic.where(topic_id: ids).where.not(feature_group_id: nil).includes(:feature_group)
                                .to_h { |m| [ m.topic_id, m.feature_group.surviving ] }
      lines = [ "- Linked threads (#{threads.size}):" ]
      threads.first(LIST_CAP).each do |t|
        parts = [ link_label(links[t.id]),
                  tags[t.id].present? ? "tags: #{tags[t.id].join(' ')}" : "not classified",
                  ("group: #{groups[t.id].name}" if groups[t.id]) ].compact
        lines << "  - topic #{t.id}: \"#{t.title}\" (#{parts.join('; ')})"
      end
      lines << "  - ... #{threads.size - LIST_CAP} more" if threads.size > LIST_CAP
      lines
    end

    def link_label(rows)
      parts = []
      parts << "shares a commit" if rows.any? { |r| r.kind == "commit" }
      mentions = rows.select { |r| r.kind == "mention" }.map(&:direction)
      parts << "this thread mentions it" if mentions.intersect?(%w[out both])
      parts << "it mentions this thread" if mentions.intersect?(%w[in both])
      fixes = rows.select { |r| r.kind == "fixes" }.map(&:direction)
      parts << "a commit here refers to its commit" if fixes.include?("out")
      parts << "its commit refers to a commit here" if fixes.include?("in")
      parts << "same commitfest entry" if rows.any? { |r| r.kind == "commitfest" }
      parts.join(", ")
    end

    def current_group_line
      membership = @topic.feature_group_topic
      group = membership&.feature_group&.surviving
      return "- Current group: none" unless group

      "- Current group: group #{group.id}, #{group.name} (#{membership_label(membership)})"
    end

    def membership_label(membership)
      run_topic = membership.classification_run_id && ClassificationRun.where(id: membership.classification_run_id).pick(:topic_id)
      return "set by a run on a linked thread" if membership.source == "llm" && run_topic && run_topic != @topic.id

      MEMBERSHIP_SOURCES[membership.source]
    end

    def groups_text(groups)
      return "None yet." if groups.empty?

      counts = FeatureGroupTopic.where(feature_group_id: groups.map(&:id)).group(:feature_group_id).count
      groups.map do |g|
        summary = g.summary.to_s.squish.truncate(SUMMARY_CAP)
        "- group #{g.id}: #{g.name} (#{count(counts.fetch(g.id, 0), 'thread')})#{": #{summary}" if summary.present?}"
      end.join("\n")
    end

    def previous_text
      return "None: this is the first run on this thread." unless @previous

      text = JSON.pretty_generate(@previous)
      id = @previous.dig("group", "id")
      return text unless id

      group = FeatureGroup.find_by(id:)&.surviving
      note = if group.nil? then "no longer exists; pick another group or none"
      elsif group.id == id then "is #{group.name}"
      else "has been merged into group #{group.id}, #{group.name}"
      end
      "#{text}\n\nGroup #{id} in that answer #{note}."
    end
  end
end
