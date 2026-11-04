module Lineage
  # database half of a bundle; returns the index the ingestor needs
  class BundleWriter
    def initialize(run:, topic:, candidates:, mode:, branches: nil)
      @run = run
      @topic = topic
      @candidates = candidates
      @mode = mode
      @branches = branches || method(:existing_branches)
    end

    def call(dir)
      patchsets = PatchsetEnumerator.new(@topic).call(File.join(dir, "patchsets"))
      branches = @branches.call(patchsets)
      pairs = TriangleBuilder.new(@topic, patchsets).call
      entries = with_reviewers(fold_backports(all_candidates))
      previous = PatchsetRun.current_for(@topic.id)&.raw_result
      last_id = JobBundle.new(run: @run, topic: @topic, patchsets: patchsets, candidates: entries, pairs: pairs,
                              branches: branches, previous: previous, mode: @mode).write(dir)
      { "mode" => @mode, "through_message_id" => last_id,
        "patchsets" => patchsets.map { |p| { "message_id" => p.message.id } },
        "candidates" => entries.map { |c|
          { "sha" => c[:commit].sha, "origin" => c[:origin],
            "backports" => c[:backports].map(&:sha), "reviewers" => c[:reviewers],
            "committer_reviewers" => c[:committer_reviewers] }
        } }
    end

    private

    def existing_branches(patchsets)
      PatchBranch.where(message_id: patchsets.map { |p| p.message.id }).index_by(&:message_id)
                 .transform_values { |r| BranchApplier.summarize(r) }
    end

    # the ingestor drops llm links for commits this run did not judge, so every
    # currently linked commit must be judged again
    def all_candidates
      return @candidates if @mode == "lineage"

      known = @candidates.map { |c| c[:commit].id }.to_set
      previous = Commit.where(id: CommitTopic.llm.where(topic_id: @topic.id).select(:commit_id))
                       .reject { |c| known.include?(c.id) }
                       .map { |c| { commit: c, origin: "previous", overlap: nil } }
      @candidates + previous
    end

    # a backport folds into its canonical commit when that is a candidate too,
    # otherwise it stays a candidate of its own
    def fold_backports(candidates)
      by_sha = candidates.index_by { |c| c[:commit].sha }
      groups = candidates.group_by { |c|
        parent = c[:commit].cherry_picked_from_sha
        by_sha.key?(parent) ? parent : c[:commit].sha
      }
      groups.map do |sha, members|
        canonical = by_sha[sha]
        origin = members.any? { |m| m[:origin] == "trailer" } ? "trailer" : canonical[:origin]
        canonical.merge(origin: origin, backports: members.map { |m| m[:commit] } - [ canonical[:commit] ])
      end
    end

    def with_reviewers(candidates)
      ids = candidates.flat_map { |c| [ c[:commit], *c[:backports] ].map(&:id) }
      people = CommitPerson.parsed.where(commit_id: ids, role: [ "reviewer", CommitPerson::COMMITTER ])
                           .includes(person: :default_alias).group_by(&:commit_id)
      candidates.map do |c|
        commits = [ c[:commit], *c[:backports] ]
        rows = commits.flat_map { |commit| people[commit.id] || [] }
        reviewers = rows.select { |r| r.role == "reviewer" }.map { |r| CommitterReviews.name(r) }.compact.uniq
        c.merge(reviewers: reviewers, committer_reviewers: CommitterReviews.names(commits, rows))
      end
    end
  end
end
