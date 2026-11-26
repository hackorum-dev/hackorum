module FeatureGroups
  # Per-major status of a feature group, computed from its member threads'
  # commits. One change is all commits sharing coalesce(cherry_picked_from_sha, sha).
  module Versions
    HASH_TOKEN = /\b[0-9a-f]{7,40}\b/
    SLICE = 1000

    Change = Struct.new(:key, :commits, :topic_ids, :major) do
      def ids = commits.map(&:id)

      def at = commits.map(&:committed_at).min

      def cherry_picked? = commits.any?(&:cherry_picked_from_sha)

      def revert? = commits.any? { |c| c.subject.start_with?("Revert") }

      def tokens = commits.flat_map { |c| c.body.to_s.scan(HASH_TOKEN) }.uniq
    end

    class << self
      # { major => { status:, commit_ids:, topic_ids:, size:, role:, changes:, lines_added:, lines_removed: } }
      def compute(topic_ids)
        topic_ids = Array(topic_ids).uniq
        return {} if topic_ids.empty? || !User.exists?(username: Classify::BOT_USERNAME)

        tags = Classify::BotNote.tags_by_topic(topic_ids)
        sized = topic_ids.select { |id| Classify::SIZED_KINDS.include?(Classify.kind(tags[id] || [])) }
        return {} if sized.empty?

        changes = changes_for(topic_ids)
        features = changes.select { |c| c.major && !c.cherry_picked? && !c.revert? && c.topic_ids.intersect?(sized) }
        released = ga_majors
        result = features.group_by(&:major).to_h do |major, feats|
          revert = revert_for(feats, changes.select { |c| c.major == major && c.revert? })
          status = if revert then "reverted" elsif released.include?(major) then "shipped" else "in-development" end
          contributing = feats.flat_map(&:topic_ids).uniq.intersection(sized).sort
          detail = { status: status, commit_ids: (feats + [ revert ]).compact.flat_map(&:ids).sort,
                     changes: feats.size, **line_totals(feats) }
          [ major, detail.merge(summarize(contributing, tags)) ]
        end
        worked_on(sized, result.keys).each do |major, active|
          result[major] = { status: "worked-on", commit_ids: [], changes: 0, lines_added: nil, lines_removed: nil }
                          .merge(summarize(active.sort, tags))
        end
        result.sort.to_h
      end

      def refresh!(group_ids)
        Array(group_ids).uniq.sort.each do |group_id|
          FeatureGroup.transaction do
            next unless FeatureGroup.lock.find_by(id: group_id)

            scope = FeatureGroupVersion.where(feature_group_id: group_id)
            human = scope.where(source: "human").pluck(:major)
            computed = compute(FeatureGroupTopic.where(feature_group_id: group_id).pluck(:topic_id))
            scope.where(source: "computed").where.not(major: computed.keys).delete_all
            scope.where(source: "human").where.not(major: computed.keys).update_all(details: nil, updated_at: Time.current)
            next if computed.empty?

            computed.slice(*human).each do |major, v|
              scope.where(source: "human", major: major).update_all(details: details_for(v), updated_at: Time.current)
            end
            rows = computed.except(*human).map do |major, v|
              { feature_group_id: group_id, major: major, status: v[:status], role: v[:role], source: "computed",
                details: details_for(v) }
            end
            FeatureGroupVersion.upsert_all(rows, unique_by: %i[feature_group_id major]) if rows.any?
          end
        end
      end

      # savepoint + report: a version bug must not fail the caller
      def refresh_isolated!(group_ids)
        FeatureGroup.transaction(requires_new: true) { refresh!(group_ids) }
      rescue StandardError => e
        Rails.error.report(e, handled: true, source: "feature_groups.versions")
      end

      def refresh_for_commits!(commit_ids)
        group_ids = Array(commit_ids).uniq.each_slice(SLICE).flat_map do |ids|
          members = change_members(change_keys(ids)).select(:id)
          FeatureGroupTopic.where(topic_id: CommitTopic.where(commit_id: members).select(:topic_id))
                           .where.not(feature_group_id: nil).distinct.pluck(:feature_group_id)
        end
        refresh!(group_ids)
      end

      def refresh_unreleased!
        refresh!(FeatureGroupVersion.where(status: "in-development").distinct.pluck(:feature_group_id))
      end

      private

      def details_for(version)
        version.except(:status, :role).transform_keys(&:to_s)
      end

      def summarize(topic_ids, tags)
        sizes = topic_ids.filter_map { |id| Classify.size(tags[id] || []) }
        { topic_ids: topic_ids,
          size: Classify::SIZE_TAGS.find { |t| sizes.include?(t) },
          role: topic_ids.all? { |id| Classify.enhancement?(tags[id] || []) } ? "improved" : "new" }
      end

      def line_totals(feats)
        originals = feats.filter_map { |f| f.commits.find { |c| c.sha == f.key } }
        %i[lines_added lines_removed].to_h do |col|
          values = originals.filter_map(&col)
          [ col, values.empty? ? nil : values.sum ]
        end
      end

      def change_keys(commit_ids)
        Commit.where(id: commit_ids).pluck(:sha, :cherry_picked_from_sha).map { |sha, from| from || sha }.uniq
      end

      def change_members(keys)
        Commit.where(sha: keys).or(Commit.where(cherry_picked_from_sha: keys))
      end

      def changes_for(topic_ids)
        topics_by_commit = CommitTopic.where(topic_id: topic_ids).pluck(:commit_id, :topic_id)
                                      .group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
        return [] if topics_by_commit.empty?

        keys = change_keys(topics_by_commit.keys)
        commits = change_members(keys).select(:id, :sha, :cherry_picked_from_sha, :subject, :body, :committed_at, :branches, :lines_added, :lines_removed)
        points = Stats::Period::Cycle.branch_points
        commits.group_by { |c| c.cherry_picked_from_sha || c.sha }.slice(*keys).map do |key, members|
          topics = members.flat_map { |c| topics_by_commit[c.id] || [] }.uniq
          Change.new(key, members, topics, major_for(members, points))
        end
      end

      # Lowest stable branch holding a member, else the major master was open
      # for when the change landed. nil before 10 (REL9_6_STABLE style).
      def major_for(commits, points)
        parts = commits.flat_map(&:branches).filter_map { |b| Commit.stable_branch_parts(b) }
        return nil if parts.any? { |_, minor| minor }
        return parts.map(&:first).min if parts.any?
        return nil unless commits.any? { |c| c.branches.include?(Commit::MASTER) }

        at = commits.map(&:committed_at).min
        branched = points.select { |_, time| time && time <= at }.last
        branched && branched.first + 1
      end

      def ga_majors
        ReleaseTag.where("name ~ ?", '^REL_\d+_0$').pluck(:name).to_set { |name| name[/\d+/].to_i }
      end

      # A Revert in N naming the first feature commit of N or most of them,
      # with no feature commit of N landing after it.
      def revert_for(feats, reverts)
        first = feats.min_by { |c| [ c.at, c.key ] }
        reverts.sort_by(&:at).find do |revert|
          next false if feats.any? { |f| f.at > revert.at }

          tokens = revert.tokens
          named = feats.select { |f| tokens.any? { |t| f.key.start_with?(t) } }
          named.include?(first) || named.size * 2 > feats.size
        end
      end

      def worked_on(topic_ids, taken)
        Stats::Period::Cycle.available.filter_map do |cycle|
          major = cycle.major + 1
          next if taken.include?(major)

          active = Message.where(topic_id: topic_ids, created_at: cycle.start...cycle.end_at).distinct.pluck(:topic_id)
          [ major, active ] if active.any?
        end
      end
    end
  end
end
