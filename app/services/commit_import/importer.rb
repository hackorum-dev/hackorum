require "cgi"

module CommitImport
  class Importer
    INSERT_BATCH = 500
    PERSON_RELINK_WINDOW = 90.days
    MIN_GROUPING_SUBJECT = 10

    def initialize(repository: nil, fetch: true, limit: nil, logger: Rails.logger)
      @repo = repository || Repository.new
      @fetch = fetch
      @limit = limit
      @logger = logger
    end

    # Pass order, load-bearing parts only:
    # - import_new_commits before import_release_tags: assign_release only
    #   touches already-inserted commits, and a tag is marked known the
    #   moment it is recorded, so a commit missing from the table when its
    #   tag is processed never gets a release, permanently.
    # Everything else here is order-independent: update_branch_sets vs
    # import_release_tags, and assign_backports vs retry_unresolved_message_ids,
    # do not depend on each other. Do not read significance into their order.
    def run!
      @repo.sync!(fetch: @fetch)
      branch_map = build_branch_map
      imported = import_new_commits(branch_map)
      update_branch_sets(branch_map)
      import_release_tags
      assign_backports if imported
      retry_unresolved_message_ids
      relink_people!(since: PERSON_RELINK_WINDOW.ago)
    end

    # Re-resolves NULL person_id rows. since: nil scans every commit
    # (explicit maintenance call); a time limits it to recent commits, for
    # the hourly job so it does not rescan the whole table.
    def relink_people!(since: nil)
      scope = CommitPerson.where(person_id: nil)
      scope = scope.joins(:commit).where(commits: { committed_at: since.. }) if since

      scope.in_batches(of: 1000) do |batch|
        entries = batch.map { |row| { id: row.id, raw_name: row.raw_name, raw_email: row.raw_email } }
        resolve_person_ids(entries)

        entries.select { |entry| entry[:person_id] }
               .group_by { |entry| entry[:person_id] }
               .each do |person_id, group|
          CommitPerson.where(id: group.map { |entry| entry[:id] }).update_all(person_id: person_id)
        end
      end
    end

    # Re-derives people, topic links and cherry-pick refs from STORED commit
    # bodies, no git access. For use after a TrailerParser change.
    def reparse!
      Commit.select(:id, :sha, :subject, :body, :committer_name, :committer_email)
            .in_batches(of: INSERT_BATCH) do |batch|
        commits = batch.to_a
        parsed = commits.to_h do |commit|
          [ commit.sha, TrailerParser.new(subject: commit.subject, body: commit.body).parse ]
        end
        id_by_sha = commits.to_h { |commit| [ commit.sha, commit.id ] }
        topic_map = message_topic_map(parsed.values.flat_map(&:message_ids).uniq)

        Commit.transaction do
          CommitPerson.where(commit_id: id_by_sha.values).delete_all
          rewrite_people(commits, parsed)

          # Drop old links first: a topic that lost its only link during
          # reparse still needs its aggregates refreshed down.
          touched = CommitTopic.where(commit_id: id_by_sha.values).pluck(:topic_id).to_set
          CommitTopic.where(commit_id: id_by_sha.values).delete_all
          touched.merge(insert_topic_links(parsed, id_by_sha, topic_map))
          update_unresolved(parsed, id_by_sha, topic_map)
          update_cherry_picks(parsed, id_by_sha)
          # aggregate refresh commits with the rows that produced it, in the
          # same batch transaction, so a crash later in the run cannot leave it
          # stale
          refresh_commit_aggregates(touched)
        end
      end
      # explicit trailer wins first, then the subject/author fallback refills
      # whatever a parser fix left NULL
      assign_backports
    end

    private

    def log(message)
      @logger&.info("[commit_import] #{message}")
    end

    # sha => [branch names]. Always computed in full: cutting a new stable
    # branch retroactively adds existing commits to it.
    def build_branch_map
      map = {}
      @repo.branches.each do |name, ref|
        shas = @repo.rev_list(ref)
        log("#{name}: #{shas.size} commits")
        shas.each { |sha| (map[sha] ||= []) << name }
      end
      map
    end

    # Returns whether any commit was actually imported, so callers can skip
    # passes that only matter when new commits arrived.
    def import_new_commits(branch_map)
      known = Commit.pluck(:sha).to_set
      pending = branch_map.keys.reject { |sha| known.include?(sha) }
      pending = pending.first(@limit) if @limit
      if pending.empty?
        log("no new commits")
        return false
      end

      log("importing #{pending.size} commits")
      @repo.commits(pending).each_slice(INSERT_BATCH) do |records|
        insert_records(records, branch_map)
      end
      true
    end

    def insert_records(records, branch_map)
      parsed = records.to_h do |record|
        [ record.sha, TrailerParser.new(subject: record.subject, body: record.body).parse ]
      end
      topic_map = message_topic_map(parsed.values.flat_map(&:message_ids).uniq)

      Commit.transaction do
        id_by_sha = insert_commits(records, parsed, branch_map, topic_map)
        insert_files(records, id_by_sha)
        insert_people(records, parsed, id_by_sha)
        touched = insert_topic_links(parsed, id_by_sha, topic_map)
        # aggregate refresh commits with the commit_topics rows that produced
        # it, so a crash later in run! cannot leave it permanently short
        refresh_commit_aggregates(touched)
      end
    end

    def insert_commits(records, parsed, branch_map, topic_map)
      now = Time.current
      rows = records.map do |record|
        result = parsed[record.sha]
        unresolved = result.message_ids.reject { |raw| topic_map[raw] }
        {
          sha: record.sha, subject: record.subject.to_s, body: record.body,
          authored_at: record.authored_at, committed_at: record.committed_at,
          author_name: record.author_name, author_email: record.author_email,
          committer_name: record.committer_name, committer_email: record.committer_email,
          branches: branch_map[record.sha] || [],
          cherry_picked_from_sha: result.cherry_picked_from,
          unresolved_message_ids: unresolved,
          created_at: now, updated_at: now
        }
      end

      result = Commit.insert_all(rows, returning: %w[sha id])
      result.rows.to_h { |sha, id| [ sha, id ] }
    end

    def insert_files(records, id_by_sha)
      rows = records.flat_map do |record|
        commit_id = id_by_sha[record.sha]
        next [] unless commit_id

        record.files.map { |path| { commit_id: commit_id, path: path } }
      end
      CommitFile.insert_all(rows) if rows.any?
    end

    def insert_people(records, parsed, id_by_sha)
      entries = records.flat_map do |record|
        commit_id = id_by_sha[record.sha]
        next [] unless commit_id

        people = parsed[record.sha].people.map do |person|
          { commit_id: commit_id, role: person.role, raw_name: person.name, raw_email: person.email }
        end
        people << {
          commit_id: commit_id, role: CommitPerson::COMMITTER,
          raw_name: record.committer_name, raw_email: record.committer_email&.downcase
        }
        people
      end.uniq

      return if entries.empty?

      resolve_person_ids(entries)
      CommitPerson.insert_all(entries)
    end

    # Returns the set of topic ids the upserted rows touch, so the caller can
    # refresh exactly those counters in the same transaction.
    def insert_topic_links(parsed, id_by_sha, topic_map)
      touched = Set.new
      rows = parsed.flat_map do |sha, result|
        commit_id = id_by_sha[sha]
        next [] unless commit_id

        result.message_ids.filter_map do |raw|
          topic_id = topic_map[raw]
          next unless topic_id

          touched << topic_id
          { commit_id: commit_id, topic_id: topic_id, external_message_id: raw }
        end
      end.uniq { |row| [ row[:commit_id], row[:topic_id] ] }

      CommitTopic.upsert_all(rows, unique_by: %i[commit_id topic_id]) if rows.any?
      touched
    end

    # Fills entry[:person_id] in place. Email match first; then an exact
    # case-insensitive name match, but only when it points at a single person.
    def resolve_person_ids(entries)
      emails = entries.filter_map { |e| e[:raw_email].presence&.downcase }.uniq
      names = entries.filter_map { |e| e[:raw_name].presence&.downcase if e[:raw_email].blank? }.uniq

      by_email = {}
      if emails.any?
        by_email = Alias.where("lower(trim(email)) IN (?)", emails)
                        .pluck(Arel.sql("lower(trim(email))"), :person_id).to_h
      end

      by_name = {}
      if names.any?
        by_name = Alias.where("lower(name) IN (?)", names)
                       .pluck(Arel.sql("lower(name)"), :person_id)
                       .group_by(&:first)
                       .transform_values { |pairs| pairs.map(&:last).uniq }
      end

      entries.each do |entry|
        email = entry[:raw_email].presence&.downcase
        entry[:person_id] = if email
          by_email[email]
        else
          candidates = by_name[entry[:raw_name].to_s.downcase] || []
          candidates.size == 1 ? candidates.first : nil
        end
      end
    end

    # raw trailer id => topic_id (nil when the message is not in the archive)
    def message_topic_map(raw_ids)
      return {} if raw_ids.empty?

      normalized = raw_ids.index_with { |raw| resolve_message_id(raw) }
      found = Message.where(message_id: normalized.values.uniq.reject(&:blank?))
                     .pluck(:message_id, :topic_id).to_h
      normalized.transform_values { |norm| found[norm] }
    end

    # unescapeURIComponent, not unescape: the id sits in a URL path, where a
    # "+" is a literal plus. Form decoding turns it into a space, which the
    # normalizer then strips, and the id never matches.
    def resolve_message_id(raw)
      MessageIdOverrides.apply(MessageIdNormalizer.normalize(CGI.unescapeURIComponent(raw)))
    end

    # commit_count and last_commit_at are both derived from commit_topics, and
    # every writer funnels through here, so one statement keeps the pair in
    # step. last_commit_at is the thread's landing date, which is what decides
    # whether a later patchset is new work - see PatchCi::CommitCutoff.
    def refresh_commit_aggregates(topic_ids)
      topic_ids = topic_ids.to_a
      return if topic_ids.empty?

      sql = ApplicationRecord.sanitize_sql_array([ <<~SQL, topic_ids ])
        UPDATE topics SET commit_count = sub.n, last_commit_at = sub.last_at
        FROM (
          SELECT t.id,
                 (SELECT COUNT(*) FROM commit_topics ct WHERE ct.topic_id = t.id) AS n,
                 (SELECT MAX(c.committed_at) FROM commit_topics ct
                    JOIN commits c ON c.id = ct.commit_id
                   WHERE ct.topic_id = t.id) AS last_at
          FROM topics t WHERE t.id IN (?)
        ) sub
        WHERE topics.id = sub.id
      SQL
      ApplicationRecord.connection.execute(sql)
    end

    # commit_people rows are wiped per-batch in reparse!, including the
    # committer row, so it has to be re-added here too, not just trailer people.
    def rewrite_people(commits, parsed)
      entries = commits.flat_map do |commit|
        people = parsed[commit.sha].people.map do |person|
          { commit_id: commit.id, role: person.role, raw_name: person.name, raw_email: person.email }
        end
        people << {
          commit_id: commit.id, role: CommitPerson::COMMITTER,
          raw_name: commit.committer_name, raw_email: commit.committer_email&.downcase
        }
        people
      end.uniq
      return if entries.empty?

      resolve_person_ids(entries)
      CommitPerson.insert_all(entries)
    end

    # May legitimately set NULL, clearing a value a parser fix no longer
    # matches. assign_backports runs after the whole reparse! pass to refill
    # the fallback for rows this leaves NULL.
    def update_cherry_picks(parsed, id_by_sha)
      parsed.each do |sha, result|
        commit_id = id_by_sha[sha]
        next unless commit_id

        Commit.where(id: commit_id).update_all(cherry_picked_from_sha: result.cherry_picked_from)
      end
    end

    def update_unresolved(parsed, id_by_sha, topic_map)
      parsed.each do |sha, result|
        commit_id = id_by_sha[sha]
        next unless commit_id

        unresolved = result.message_ids.reject { |raw| topic_map[raw] }
        Commit.where(id: commit_id).update_all(unresolved_message_ids: unresolved)
      end
    end

    # Always recomputed in full: cutting a new stable branch retroactively
    # adds existing commits to it, and a branch going away must drop them.
    def update_branch_sets(branch_map)
      changed = 0
      Commit.select(:id, :sha, :branches).in_batches(of: 2000) do |batch|
        batch.each do |commit|
          want = (branch_map[commit.sha] || []).sort
          next if want == commit.branches.sort

          Commit.where(id: commit.id).update_all(branches: want)
          changed += 1
        end
      end
      log("branch sets updated: #{changed}") if changed.positive?
    end

    RELEASE_ASSIGN_BATCH = 5000

    # Tags are walked oldest-first, each excluding all previously seen tags, so
    # every commit is assigned the earliest release that contains it. Existing
    # values are never touched, which makes a new tag a cheap backfill of the
    # rows that are still NULL.
    def import_release_tags
      known = ReleaseTag.pluck(:name)
      fresh = @repo.tags.reject { |tag| known.include?(tag[:name]) }
      return if fresh.empty?

      log("new release tags: #{fresh.map { |t| t[:name] }.join(', ')}")

      # released_at should always be set (Repository#parse_time! raises
      # rather than returning nil), but a stray nil must not blow up sort_by
      # comparing Time with nil - fall back to the epoch, oldest wins.
      fresh.sort_by { |tag| tag[:released_at] || Time.zone.at(0) }.each do |tag|
        version = ReleaseTag.normalize(tag[:name])
        exclude = known.dup
        known << tag[:name]

        # rev-list is read-only git work, done outside the transaction so the
        # DB transaction below is short - not held open across a subprocess.
        shas = version ? @repo.rev_list_excluding(tag[:name], exclude) : []

        # create! and assign_release commit together: a crash between them
        # would mark the tag known with no commit ever getting released_in,
        # and the next run skips it forever since it is already recorded.
        ReleaseTag.transaction do
          ReleaseTag.create!(name: tag[:name], version: version,
                             released_at: tag[:released_at], commit_sha: tag[:commit_sha])
          assign_release(shas, version, tag[:released_at]) if version
        end
      end
    end

    def assign_release(shas, version, released_at)
      shas.each_slice(RELEASE_ASSIGN_BATCH) do |slice|
        Commit.where(sha: slice, released_in: nil)
              .update_all(released_in: version, released_at: released_at)
      end
    end

    # Backports carry the original commit message, so (subject, author_email)
    # identifies the change and the earliest commit is the canonical one. Only
    # rows still NULL are touched, so an explicit cherry-pick reference wins.
    def assign_backports
      sql = ApplicationRecord.sanitize_sql_array([ <<~SQL, MIN_GROUPING_SUBJECT ])
        WITH canonical AS (
          SELECT DISTINCT ON (subject, author_email) id, sha, subject, author_email
          FROM commits
          ORDER BY subject, author_email, committed_at ASC, id ASC
        )
        UPDATE commits c
        SET cherry_picked_from_sha = canonical.sha
        FROM canonical
        WHERE c.subject = canonical.subject
          AND c.author_email = canonical.author_email
          AND c.id <> canonical.id
          AND c.cherry_picked_from_sha IS NULL
          AND length(c.subject) >= ?
      SQL
      ApplicationRecord.connection.execute(sql)
    end

    def retry_unresolved_message_ids
      Commit.where("cardinality(unresolved_message_ids) > 0")
            .select(:id, :unresolved_message_ids)
            .in_batches(of: 500) do |batch|
        commits = batch.to_a
        topic_map = message_topic_map(commits.flat_map(&:unresolved_message_ids).uniq)
        next if topic_map.values.compact.empty?

        rows = []
        remaining_by_id = {}
        touched = Set.new
        commits.each do |commit|
          resolved = commit.unresolved_message_ids.select { |raw| topic_map[raw] }
          next if resolved.empty?

          resolved.each do |raw|
            touched << topic_map[raw]
            rows << { commit_id: commit.id, topic_id: topic_map[raw], external_message_id: raw }
          end
          remaining_by_id[commit.id] = commit.unresolved_message_ids - resolved
        end

        next if rows.empty?

        Commit.transaction do
          # group by the resulting array so commits that end up with the
          # same remainder (almost always []) share one bulk update instead
          # of one round trip each
          remaining_by_id.group_by { |_id, remaining| remaining }.each do |remaining, pairs|
            Commit.where(id: pairs.map(&:first)).update_all(unresolved_message_ids: remaining)
          end
          CommitTopic.upsert_all(rows.uniq { |r| [ r[:commit_id], r[:topic_id] ] },
                                unique_by: %i[commit_id topic_id])
          refresh_commit_aggregates(touched)
        end
      end
    end
  end
end
