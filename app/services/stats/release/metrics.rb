module Stats
  class Release
    # The per-commit numbers of a release, over any subset of its scope commits:
    # the whole scope for Overview, one person's commits for the person view.
    class Metrics
      include Stats::Numbers

      def initialize(scopes, commit_ids)
        @scopes = scopes
        @ids = commit_ids.to_a
      end

      attr_reader :ids

      def count = ids.size

      def commits = Commit.where(id: ids)

      def reverts = commits.where("subject ILIKE 'Revert%'").count

      def lines = [ commits.sum(:lines_added), commits.sum(:lines_removed) ]

      def with_thread = Commit.where(id: CommitTopic.where(commit_id: ids).select(:commit_id)).count

      # days from the oldest linked thread's first message to the commit, one
      # value per commit that has a thread
      def thread_ages_days
        @thread_ages_days ||= commits.joins(:commit_topics).joins("JOIN topics ON topics.id = commit_topics.topic_id")
                                     .group("commits.id, commits.committed_at")
                                     .pluck(Arel.sql("EXTRACT(EPOCH FROM (commits.committed_at - MIN(topics.created_at))) / 86400"))
                                     .map(&:to_f)
      end

      def verdict_rows
        @verdict_rows ||= begin
          set = ids.to_set
          @scopes.verdicts.rows.select { |r| set.include?(r.scope_commit_id) }
        end
      end

      def verdict_counts
        by = verdict_rows.map(&:verdict).tally
        { as_is: by.fetch("as_is", 0), modified: by.fetch("modified", 0), partial: by.fetch("partial", 0), from_discussion: by.fetch("from_discussion", 0) }
      end

      def change_levels
        by = verdict_rows.select { |r| r.verdict == "modified" }.map(&:change_level).tally
        { light: by.fetch("light", 0), moderate: by.fetch("moderate", 0), significant: by.fetch("significant", 0) }
      end

      def chain_lengths
        @chain_lengths ||= @scopes.verdicts.chain_lengths_for(verdict_rows.select(&:source_message_id).map(&:id))
      end

      def cf_commits
        commits.where(id: CommitTopic.where(topic_id: CommitfestPatchTopic.select(:topic_id)).select(:commit_id)).count
      end

      def credited_counts
        @credited_counts ||= CommitPerson.parsed.where(commit_id: ids, role: "reviewer").group(:commit_id).count
      end

      def trailer_coverage
        counts = verdict_rows.flat_map(&:reviews)
                             .select { |r| review_source(r) == "trailer" && r["note"] != "not assessed" }
                             .map { |r| r["coverage"] }.tally
        { final: counts.fetch("final", 0), earlier: counts.fetch("earlier", 0), none: counts.fetch("none", 0) }
      end

      def uncredited_reviewed
        credited = credited_counts.keys.to_set
        llm = verdict_rows.reject { |r| credited.include?(r.scope_commit_id) }
                          .map { |r| r.reviews.count { |rv| rv["source"] == "llm" } }
                          .select(&:positive?)
        { count: llm.size, of: count - credited.size, credits: llm.sum }
      end

      def by_others_ids
        @by_others_ids ||= CommitterReviewer.new(ids).others_commit_ids
      end

      def committer_authored_ids
        CommitPerson.where(source: %w[parsed llm], commit_id: by_others_ids, role: %w[author co_author], person_id: @scopes.committer_ids)
                    .distinct.pluck(:commit_id)
      end

      def judged_ids
        @judged_ids ||= begin
          set = by_others_ids.to_set
          verdict_rows.map(&:scope_commit_id).select { |id| set.include?(id) }
        end
      end

      def alone_ids
        @alone_ids ||= judged_ids - reviewed_by_someone_else(judged_ids)
      end

      def sizes
        @sizes ||= Commit.where(id: by_others_ids).pluck(:id, Arel.sql("COALESCE(lines_added, 0) + COALESCE(lines_removed, 0)")).to_h
      end

      private

      # a reviews row without a source is a trailer row written before the
      # source key existed
      def review_source(review) = review["source"] || "trailer"

      # a credited reviewer, or any reviews row the LLM wrote, that is not the
      # committer
      def reviewed_by_someone_else(subset)
        committers = CommitPerson.parsed.where(commit_id: subset, role: CommitPerson::COMMITTER)
                                 .includes(person: :default_alias).index_by(&:commit_id)
        credited = CommitPerson.parsed.where(commit_id: subset, role: "reviewer")
                               .reject { |p| committers[p.commit_id] && CommitterReviewer.same_person?(p, committers[p.commit_id]) }
                               .map(&:commit_id)
        set = subset.to_set
        seen = verdict_rows.select { |r| set.include?(r.scope_commit_id) && r.reviews.any? { |rv| others_review?(rv, committers[r.scope_commit_id]) } }
                           .map(&:scope_commit_id)
        (credited + seen).uniq
      end

      def others_review?(review, committer)
        return false if review_source(review) == "committer"
        return true unless committer && review["reviewer"].present?

        names = [ committer.raw_name, committer.person&.display_name ].compact.map(&:squish)
        names.none? { |n| n.casecmp?(review["reviewer"].squish) }
      end
    end
  end
end
