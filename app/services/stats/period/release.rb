module Stats
  class Period
    # One major version as a statistics subject: branch names, the tags that
    # bound its cycle, and whether it is finished. The commit set is branch
    # based (in this branch, not in the previous one), and the cycle has
    # three phases. Reads release_tags only.
    class Release < Period
      FIRST_MAJOR = 10

      attr_reader :major

      # every major with a branch (a beta1 tag), newest first, plus the next
      # major while master already has commits past the newest branch
      def self.available
        majors = ReleaseTag.where("name ~ ?", '^REL_\d+_BETA1$')
                           .pluck(:name).map { |n| n[/\d+/].to_i }
                           .select { |m| m >= FIRST_MAJOR }.sort.reverse
        return [] if majors.empty?

        newest = majors.first
        dev = Commit.where("'master' = ANY(branches) AND NOT (? = ANY(branches))", "REL_#{newest}_STABLE")
        list = majors.map { |m| new(m) }.select { |r| r.start.present? }
        dev.exists? ? [ new(newest + 1) ] + list : list
      end

      def initialize(major)
        @major = major.to_i
      end

      def key = major.to_s

      def label = "PG#{major}"

      def slug = label.downcase

      def noun = "cycle"

      def pill_noun = "release"

      def in_development? = beta1_tag.nil?

      def in_progress? = in_development?

      def in_progress_label = "in development"

      def branch = in_development? ? "master" : "REL_#{major}_STABLE"

      def previous_branch = "REL_#{major - 1}_STABLE"

      def closed? = ga_tag.present?

      def companies? = major >= COMPANIES_FROM_MAJOR

      def start = tag_time("REL_#{major - 1}_BETA1")

      def previous_ga = tag_time("REL_#{major - 1}_0")

      def branch_point = tag_time("REL_#{major}_BETA1")

      def end_at = @end_at ||= ga_at || Time.current

      def ga_at = tag_time("REL_#{major}_0")

      def range_text
        from = "Cycle: #{I18n.l(start.to_date)} (#{major - 1} branched)"
        to = closed? ? "to #{I18n.l(end_at.to_date)} (#{major}.0)" : "to #{label} GA (not yet tagged)"
        "#{from} #{to}"
      end

      def scope_description = "commits in the #{major} branch that are not in #{major - 1}"

      def backported_description = "to an earlier branch too"

      # the middle window needs the previous GA, the late one the branch point
      def windows
        @windows ||= begin
          ga = previous_ga
          bp = branch_point
          finish = end_at
          list = []
          if ga.nil?
            list << [ start, bp || finish, :early ]
            list << [ bp, finish, :late ] if bp
          else
            list << [ start, ga, :early ]
            list << [ ga, bp || finish, :middle ]
            list << [ bp, finish, :late ] if bp
          end
          list
        end
      end

      # own and previous major only; the previous one just for its GA
      def events
        ReleaseTag.where(released_at: start..end_at)
                  .where("name ~ ?", "^REL_(#{major - 1}|#{major})_(BETA\\d+|RC\\d+|0)$")
                  .order(:released_at)
                  .filter_map do |tag|
          tag_major, part = tag.name.match(EVENT_TAG).captures
          label = release_event_label(tag_major.to_i, part)
          label && { at: tag.released_at, label: label }
        end
      end

      # one row per logical change: the canonical member when it is in the
      # branch, else the backport that is (a post-branch fix lands on master
      # as something the branch never sees, and reaches it as a cherry-pick).
      # A group with a member on the previous branch before that release's
      # GA shipped there first and is not counted again here
      def representatives_sql
        conn = Commit.connection
        this = conn.quote(branch)
        previous = conn.quote(previous_branch)
        ga = ga_at && conn.quote(ga_at.utc.iso8601)
        prev_ga = previous_ga && conn.quote(previous_ga.utc.iso8601)
        <<~SQL.squish
          SELECT DISTINCT ON (COALESCE(cherry_picked_from_sha, sha)) *
          FROM commits
          WHERE #{this} = ANY(branches)
            AND NOT (#{previous} = ANY(branches))
            AND COALESCE(cherry_picked_from_sha, sha) NOT IN (
              SELECT COALESCE(cherry_picked_from_sha, sha) FROM commits
              WHERE #{previous} = ANY(branches) #{prev_ga ? "AND committed_at <= #{prev_ga}" : ''})
            #{ga ? "AND committed_at <= #{ga}" : ''}
          ORDER BY COALESCE(cherry_picked_from_sha, sha), (cherry_picked_from_sha IS NULL) DESC, committed_at, sha
        SQL
      end

      # groups with a member in an earlier stable branch, matched by group
      # key: a post-branch fix is represented by its branch cherry-pick,
      # while the older backports point at the master commit
      def backported_keys
        @backported_keys ||= Commit.where("COALESCE(cherry_picked_from_sha, sha) IN (SELECT COALESCE(cherry_picked_from_sha, sha) FROM (#{representatives_sql}) AS scope)")
                                   .where.not("? = ANY(branches)", branch)
                                   .where("branches && ARRAY[?]::varchar[]", earlier_branches)
                                   .distinct.pluck(Arel.sql("COALESCE(cherry_picked_from_sha, sha)"))
      end

      # threads of what shipped in the previous major before its GA; nil
      # while that GA is not tagged
      def previous_landed_topics
        ga = previous_ga or return nil
        CommitTopic.joins(:commit).where("? = ANY(commits.branches)", previous_branch)
                   .where(commits: { committed_at: ...ga }).select(:topic_id)
      end

      private

      def beta1_tag = tag_time("REL_#{major}_BETA1")

      def ga_tag = tag_time("REL_#{major}_0")

      def earlier_branches
        (FIRST_MAJOR...major).map { |m| "REL_#{m}_STABLE" }
      end

      def release_event_label(tag_major, part)
        if tag_major == major - 1
          part == "0" ? "#{tag_major}.0 GA" : nil
        elsif part == "0"
          "#{tag_major}.0 GA"
        elsif part == "BETA1"
          "#{tag_major} branched (beta1)"
        else
          part.downcase
        end
      end

      def tag_time(name)
        @tags ||= {}
        return @tags[name] if @tags.key?(name)

        @tags[name] = ReleaseTag.where(name: name).pick(:released_at)
      end
    end
  end
end
