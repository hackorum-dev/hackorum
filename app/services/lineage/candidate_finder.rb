module Lineage
  # Candidate commits for a topic (trailers) and candidate topics for a commit
  # (changed-file overlap against patch_submission_files). score = sum of
  # idf(path) over matched paths (noise paths weighted 0.25) * (0.5 + 0.5 * jaccard),
  # idf = log(corpus messages / (1 + messages containing path)).
  class CandidateFinder
    WINDOW_DAYS = 90
    TOP = 3
    MIN_PATCHSETS = 2
    MAX_DF = 2000
    NOISE_WEIGHT = 0.25
    NOISE_PATH_RE = %r{
      \Aconfigure(\.in|\.ac)?\z |
      \Adoc/src/sgml/release.*\.sgml\z |
      \.po\z |
      \Asrc/tools/pgindent/typedefs\.list\z
    }x

    def self.trailer_commits(topic)
      Commit.for_topic(topic.id, sources: %w[trailer]).to_a
    end

    def initialize(corpus_size: nil)
      @corpus_size = corpus_size
    end

    # [{ topic_id:, message_id:, score:, jaccard:, matched_paths:, n_overlap:, date_gap_days:, submitted_at: }]
    def overlap_topics(commit)
      files = commit.commit_files.pluck(:path)
      return [] if files.empty?

      df = PatchSubmissionFile.where(path: files).group(:path).count
      usable = files.reject { |p| df.fetch(p, 0) > MAX_DF }
      return [] if usable.empty?

      cfiles = usable.to_set

      window = (commit.committed_at - WINDOW_DAYS.days)..commit.committed_at
      hits = PatchSubmissionFile.joins(:message)
                                .where(path: usable, messages: { created_at: window })
                                .distinct
                                .pluck(:message_id)
      return [] if hits.empty?

      paths_by_message = PatchSubmissionFile.where(message_id: hits).pluck(:message_id, :path)
                                            .group_by(&:first).transform_values { |rows| rows.map(&:last).to_set }
      messages = Message.where(id: hits).order(:created_at, :id).pluck(:id, :topic_id, :created_at)
      counts = Message.where(topic_id: messages.map { |_, t, _| t }.uniq, is_patch_submission: true)
                      .group(:topic_id).count

      best = {}
      messages.each do |id, topic_id, created_at|
        next if counts.fetch(topic_id, 0) < MIN_PATCHSETS
        paths = paths_by_message[id]
        inter = cfiles & paths
        next if inter.all? { |p| noise?(p) }

        cand = score(cfiles, paths, inter, df, commit.committed_at - created_at)
                 .merge(topic_id: topic_id, message_id: id, submitted_at: created_at)
        best[topic_id] = cand if best[topic_id].nil? || cand[:score] > best[topic_id][:score]
      end
      best.values.sort_by { |c| [ -c[:score], c[:submitted_at], c[:topic_id] ] }.first(TOP)
    end

    private

    def corpus_size
      @corpus_size ||= [ PatchSubmissionFile.distinct.count(:message_id), 1 ].max
    end

    def idf(path, df) = Math.log(corpus_size / (1.0 + df.fetch(path, 0)))

    def noise?(path) = path.match?(NOISE_PATH_RE)

    def score(cfiles, paths, inter, df, gap)
      idf_sum = inter.sum { |p| noise?(p) ? idf(p, df) * NOISE_WEIGHT : idf(p, df) }
      jac = inter.size.fdiv((cfiles | paths).size)
      { score: (idf_sum * (0.5 + 0.5 * jac)).round(4), jaccard: jac.round(4),
        n_overlap: inter.size, matched_paths: inter.sort, date_gap_days: (gap / 86_400).floor }
    end
  end
end
