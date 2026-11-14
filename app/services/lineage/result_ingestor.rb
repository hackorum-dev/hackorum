require "json"

module Lineage
  class ResultIngestor
    Error = Class.new(StandardError)
    # the run an update builds on was deleted under it; not the run's fault
    BaseGone = Class.new(StandardError)

    LEVELLED = %w[modified partial].freeze
    NO_SOURCE = %w[other_thread].freeze
    SUGGESTED_COVERAGES = %w[final earlier].freeze
    NOT_ASSESSED = { "reviewed_message_ids" => [], "coverage" => "none", "note" => "not assessed", "source" => "trailer" }.freeze

    def initialize(run:, index:, link_threshold: 0.8, link: true, mode: nil)
      @run = run
      @index = index
      @threshold = link_threshold
      @link = link
      @mode = mode
    end

    def call(result_path)
      data = parse(result_path)
      base_run if update?
      @notes = []
      validate!(data)
      extras = dedupe_extras(data)
      found = Commit.where(sha: extras.map { |v| v["sha"] }).index_by(&:sha)
      extras, missing = extras.partition { |v| found.key?(v["sha"]) }
      known = candidate_commits.merge(found)
      missing.each { |v| @notes << "extra commit not in commits table: #{v['sha']}" }
      old_lineages, old_verdicts = carried_rows(data, known)
      @ref_shas = reference_shas(data, known)
      PatchsetRun.transaction do
        @run.lineages.delete_all
        @run.verdicts.delete_all
        PatchsetLineage.insert_all(old_lineages) if old_lineages.any?
        CommitVerdict.insert_all(old_verdicts) if old_verdicts.any?
        rows = lineage_rows(data)
        PatchsetLineage.insert_all(rows) if rows.any?
        rows = verdict_rows(data["verdicts"], known, extra: false) + verdict_rows(extras, known, extra: true)
        CommitVerdict.insert_all(rows) if rows.any?
        @run.finish!(status: "done", story: normalize(story_text(data)), raw_result: update? ? merged(data) : data,
                     error: @notes.join("\n").presence)
        judged = data["verdicts"] + extras
        if @link && judged.any?
          previously_linked = update? ? [] : CommitTopic.llm.where(topic_id: @run.topic_id).pluck(:commit_id)
          link!(judged, known)
          rebuild_credits!(judged.map { |v| known[v["sha"]].id } | previously_linked)
          ids = judged.map { |v| known[v["sha"]].id }
          CommitterReviewer.sync!(ids | previously_linked)
          CommitterReviews.mirror(@run.verdicts.where(commit_id: ids))
        end
        close_rechecks!(known)
        open_rechecks!(judged, known) unless recheck_shas.any?
      end
      @run
    rescue Error => e
      @run.finish!(status: "failed", error: e.message)
      raise
    end

    private

    def parse(path)
      raise Error, "result file missing" unless File.exist?(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      raise Error, "result is not JSON: #{e.message}"
    end

    def patchset_ids = @patchset_ids ||= @index["patchsets"].map { |p| p["message_id"] }.to_set
    def candidates = @candidates ||= @index["candidates"].index_by { |c| c["sha"] }
    def candidate_commits = @candidate_commits ||= Commit.where(sha: candidates.keys).index_by(&:sha)
    def extras(data) = data.fetch("extra_commits", [])
    def reviews(v) = v.fetch("reviews", nil) || []
    def suggested(v) = v.fetch("suggested_reviews", nil) || []
    def message_ids = @message_ids ||= @run.topic.chronological_message_ids
    def topic_message_ids = @topic_message_ids ||= message_ids.to_set
    def update? = @mode == "update"
    def discussion? = @mode == "discussion" || (update? && patchset_ids.empty?)
    def recheck_shas = @recheck_shas ||= candidates.select { |_, c| c["recheck"] }.keys.to_set
    def new_patchset_ids = @new_patchset_ids ||= @index["patchsets"].select { |p| p["new"] }.map { |p| p["message_id"] }.to_set

    def base_run
      return nil unless update?

      @base_run ||= PatchsetRun.find_by(id: @index["base_run_id"]) or
        raise BaseGone, "base run #{@index['base_run_id']} is gone"
    end

    def base_verdict_shas
      @base_verdict_shas ||= Commit.where(id: base_run.verdicts.select(:commit_id)).pluck(:sha).to_set
    end

    # base rows win; new answers for the same patchset or commit are dropped
    def carried_rows(data, known)
      return [ [], [] ] unless update?

      lineages = base_run.lineages.to_a
      recheck_ids = recheck_shas.filter_map { |s| known[s]&.id }.to_set
      verdicts = base_run.verdicts.reject { |v| recheck_ids.include?(v.commit_id) }
      taken = lineages.map(&:message_id).to_set
      data["lineage"] = data["lineage"].reject do |l|
        taken.include?(l["message_id"]).tap { |hit| @notes << "lineage for #{l['message_id']} dropped: carried from base run" if hit }
      end
      taken = verdicts.map(&:commit_id).to_set
      data["verdicts"] = data["verdicts"].reject do |v|
        taken.include?(known[v["sha"]].id).tap { |hit| @notes << "verdict for #{v['sha']} dropped: carried from base run" if hit }
      end
      [ carried(lineages), carried(verdicts) ]
    end

    def carried(rows)
      rows.map { |row| row.attributes.except("id").merge("patchset_run_id" => @run.id) }
    end

    # the next update reads this as previous, so it must be the whole picture
    def merged(data)
      prev = base_run.raw_result || {}
      data.merge("lineage" => Array(prev["lineage"]) + data["lineage"],
                 "verdicts" => Array(prev["verdicts"]).reject { |v| recheck_shas.include?(v["sha"]) } + data["verdicts"],
                 "extra_commits" => Array(prev["extra_commits"]),
                 "update" => data.except("update"))
    end

    def validate!(data)
      raise Error, "top level must be an object with lineage, verdicts, story" unless data.is_a?(Hash) &&
        data["lineage"].is_a?(Array) && data["verdicts"].is_a?(Array) && story_shape?(data["story"])
      raise Error, "extra_commits must be an array" unless extras(data).is_a?(Array)
      if @mode == "lineage" && (data["verdicts"].any? || extras(data).any?)
        raise Error, "lineage mode allows no verdicts or extra_commits"
      end
      raise Error, "update mode allows no extra_commits" if update? && extras(data).any?

      judged_ids = update? ? new_patchset_ids : patchset_ids
      seen = Set.new
      data["lineage"] = data["lineage"].select do |l|
        raise Error, "lineage entry must be an object" unless l.is_a?(Hash)
        id = l["message_id"]
        if update? && patchset_ids.include?(id) && !judged_ids.include?(id)
          @notes << "lineage for old patchset #{id} dropped"
          next false
        end
        raise Error, "unknown message id #{id}" unless judged_ids.include?(id)
        raise Error, "duplicate lineage for #{id}" unless seen.add?(id)
        parent = l["parent_message_id"]
        raise Error, "unknown parent #{parent} for #{id}" unless parent.nil? || patchset_ids.include?(parent)
        raise Error, "message #{id} cannot be its own parent" if parent == id
        raise Error, "bad step_kind #{l['step_kind']}" unless PatchsetLineage::STEP_KINDS.include?(l["step_kind"])
        check_confidence!(l["confidence"], "lineage #{id}")
        true
      end
      missing = judged_ids - seen
      raise Error, "lineage missing for message #{missing.first}" if missing.any?

      shas = Set.new
      data["verdicts"] = data["verdicts"].select do |v|
        raise Error, "verdict entry must be an object" unless v.is_a?(Hash)
        if update? && !candidates.key?(v["sha"]) && base_verdict_shas.include?(v["sha"])
          @notes << "verdict for #{v['sha']} dropped: judged by the base run"
          next false
        end
        raise Error, "unknown sha #{v['sha']}" unless candidate_commits.key?(v["sha"])
        raise Error, "duplicate verdict for #{v['sha']}" unless shas.add?(v["sha"])
        raise Error, "bad verdict #{v['verdict']}" unless CommitVerdict::VERDICTS.include?(v["verdict"])
        check_verdict!(v, "verdict #{v['sha']}")
        true
      end
      if update? && (missing_sha = (candidates.keys - shas.to_a).first)
        raise Error, "verdict missing for #{missing_sha}"
      end

      extras(data).each do |v|
        raise Error, "extra commit entry must be an object" unless v.is_a?(Hash)
        raise Error, "bad sha #{v['sha'].inspect} for extra commit" unless v["sha"].is_a?(String)
        raise Error, "bad verdict #{v['verdict']} for extra commit #{v['sha']}" unless CommitVerdict::COMMITTED.include?(v["verdict"])
        check_verdict!(v, "extra commit #{v['sha']}")
      end
    end

    def check_verdict!(v, what)
      if NO_SOURCE.include?(v["verdict"])
        cleared = %w[source_message_id author_name author_message_id change_level].select { |k| v[k] }
        cleared.each { |k| v[k] = nil }
        @notes << "#{cleared.join(', ')} cleared for other_thread #{what}" if cleared.any?
      end
      src = v["source_message_id"]
      if discussion? && src && !patchset_ids.include?(src) && topic_message_ids.include?(src)
        v["source_message_id"] = nil
        v["author_message_id"] ||= src
        @notes << "source_message_id #{src} is not a patchset, cleared for #{what}"
        src = nil
      end
      raise Error, "unknown source_message_id #{src}" unless src.nil? || patchset_ids.include?(src)
      author = v["author_message_id"]
      raise Error, "unknown author_message_id #{author} for #{what}" unless author.nil? || topic_message_ids.include?(author)
      name = v["author_name"]
      raise Error, "bad author_name #{name.inspect} for #{what}" unless name.nil? || (name.is_a?(String) && name.present?)
      check_confidence!(v["confidence"], what)
      check_change_level!(v, what)
      check_reviews!(v, what)
      check_suggested!(v, what)
    end

    def check_confidence!(value, what)
      raise Error, "bad confidence for #{what}" unless value.is_a?(Numeric) && value.between?(0, 1)
    end

    def check_change_level!(v, what)
      level = v["change_level"]
      if LEVELLED.include?(v["verdict"])
        raise Error, "bad change_level #{level.inspect} for #{what}" unless CommitVerdict::CHANGE_LEVELS.include?(level)
      elsif !level.nil?
        raise Error, "change_level must be null for #{v['verdict']} #{what}"
      end
    end

    def check_reviews!(v, what)
      raise Error, "reviews must be an array for #{what}" unless reviews(v).is_a?(Array)
      reviews(v).each do |r|
        raise Error, "review entry must be an object for #{what}" unless r.is_a?(Hash)
        raise Error, "bad reviewer #{r['reviewer'].inspect} for #{what}" unless r["reviewer"].is_a?(String) && r["reviewer"].present?
        raise Error, "bad coverage #{r['coverage']} for #{what}" unless CommitVerdict::COVERAGES.include?(r["coverage"])
        r["reviewed_message_ids"] = check_reviewed_ids!(r["reviewed_message_ids"], what)
      end
    end

    def check_suggested!(v, what)
      raise Error, "suggested_reviews must be an array for #{what}" unless suggested(v).is_a?(Array)
      suggested(v).each do |r|
        raise Error, "suggested review entry must be an object for #{what}" unless r.is_a?(Hash)
        raise Error, "bad suggested reviewer #{r['reviewer'].inspect} for #{what}" unless r["reviewer"].is_a?(String) && r["reviewer"].present?
        mid = r["reviewer_message_id"]
        raise Error, "unknown reviewer_message_id #{mid} for #{what}" unless mid.nil? || topic_message_ids.include?(mid)
        raise Error, "bad coverage #{r['coverage']} for suggested reviewer in #{what}" unless SUGGESTED_COVERAGES.include?(r["coverage"])
        r["reviewed_message_ids"] = check_reviewed_ids!(r["reviewed_message_ids"], what)
        check_confidence!(r["confidence"], "suggested reviewer #{r['reviewer']} in #{what}")
      end
    end

    def check_reviewed_ids!(ids, what)
      raise Error, "reviewed_message_ids must be an array for #{what}" unless ids.is_a?(Array)
      ids.select do |id|
        next true if patchset_ids.include?(id)
        raise Error, "unknown reviewed message #{id} for #{what}" unless discussion?

        @notes << "reviewed message #{id} is not a patchset, dropped for #{what}"
        false
      end
    end

    def dedupe_extras(data)
      shas = Set.new
      extras(data).reject { |v| candidates.key?(v["sha"]) || !shas.add?(v["sha"]) }
    end

    # older bundles ship a schema with a string story
    def story_shape?(story)
      story.is_a?(String) || (story.is_a?(Array) && story.all?(String))
    end

    def story_text(data)
      story = data["story"]
      return story unless story.is_a?(Array)

      story.map(&:strip).reject(&:empty?).join("\n")
    end

    def reference_shas(data, known)
      texts = data["lineage"].map { |l| l["reason"] } + [ story_text(data) ] +
              (data["verdicts"] + extras(data)).flat_map { |v| [ v["evidence"] ] + reviews(v).map { |r| r["note"] } + suggested(v).map { |r| r["note"] } }
      hexes = texts.compact.flat_map { |t| t.to_s.scan(References::SHA) }.map(&:downcase).uniq - known.keys
      known.keys.to_set | Commit.where(sha: hexes).pluck(:sha)
    end

    def normalize(text)
      References.normalize(text.to_s, topic: @run.topic, shas: @ref_shas, message_ids: message_ids)
    end

    def lineage_rows(data)
      data["lineage"].map do |l|
        { patchset_run_id: @run.id, topic_id: @run.topic_id, message_id: l["message_id"],
          parent_message_id: l["parent_message_id"], step_kind: l["step_kind"],
          confidence: l["confidence"].to_f, reason: normalize(l["reason"]) }
      end
    end

    def verdict_rows(list, known, extra:)
      list.map do |v|
        @notes << "reviews ignored for extra #{v['sha']}: no trailer reviewers, use suggested_reviews" if extra && reviews(v).any?
        rows = (extra ? [] : candidate_reviews(v)) + suggested_rows(v, extra: extra)
        { patchset_run_id: @run.id, topic_id: @run.topic_id, commit_id: known[v["sha"]].id,
          verdict: v["verdict"], source_message_id: v["source_message_id"], extra: extra,
          author_name: v["author_name"]&.strip, author_message_id: v["author_message_id"],
          origin: extra ? "extra" : (candidates[v["sha"]]["origin"] || "trailer"),
          change_level: v["change_level"], reviews: rows, **CommitterReviews.counts(rows),
          confidence: v["confidence"].to_f, evidence: normalize(v["evidence"]) }
      end
    end

    def candidate_reviews(v)
      candidate = candidates[v["sha"]]
      names = (candidate["reviewers"] || []).index_by { |n| n.strip.downcase }
      kept = {}
      reviews(v).each do |r|
        name = names[r["reviewer"].strip.downcase]
        if name.nil?
          @notes << "reviewer not in trailers: #{r['reviewer']} for #{v['sha']}"
        else
          kept[name] ||= review_row(r, name)
        end
      end
      rows = names.values.map { |name| kept[name] || NOT_ASSESSED.merge("reviewer" => name) }
      CommitterReviews.apply(rows, candidate["committer_reviewers"] || [], v["source_message_id"])
    end

    def review_row(r, name)
      { "reviewer" => name, "reviewed_message_ids" => r["reviewed_message_ids"],
        "coverage" => r["coverage"], "note" => normalize(r["note"]), "source" => "trailer" }
    end

    # misplaced suggestions: note and drop, do not fail a paid run
    def suggested_rows(v, extra:)
      list = suggested(v)
      return [] if list.empty?

      reason =
        if !CommitVerdict::COMMITTED.include?(v["verdict"]) then "verdict #{v['verdict']}"
        elsif !extra && (candidates[v["sha"]]["reviewers"] || []).any? then "has trailer reviewers"
        end
      if reason
        @notes << "suggested reviewers ignored for #{v['sha']}: #{reason}"
        return []
      end

      list.uniq { |r| r["reviewer"].squish.downcase }.map do |r|
        { "reviewer" => r["reviewer"].squish, "reviewed_message_ids" => r["reviewed_message_ids"].uniq, "coverage" => r["coverage"],
          "note" => normalize(r["note"]), "source" => "llm", "reviewer_message_id" => r["reviewer_message_id"],
          "confidence" => r["confidence"].to_f }
      end
    end

    def link!(judged, known)
      backports = backport_ids(judged)
      judged.each do |v|
        commit_id = known[v["sha"]].id
        next if CommitTopic.trailer.exists?(commit_id: commit_id, topic_id: @run.topic_id)

        qualifies = CommitVerdict::COMMITTED.include?(v["verdict"]) && v["confidence"].to_f >= @threshold
        if qualifies
          row = CommitTopic.llm.find_or_initialize_by(commit_id: commit_id, topic_id: @run.topic_id)
          row.update!(confidence: v["confidence"].to_f)
        else
          CommitTopic.llm.where(commit_id: [ commit_id, *backports[v["sha"]] ], topic_id: @run.topic_id).delete_all
        end
      end
      ids = judged.map { |v| known[v["sha"]].id } + backports.values.flatten
      CommitTopic.llm.where(topic_id: @run.topic_id).where.not(commit_id: ids).delete_all unless update?
    end

    # Credits come from every thread's current verdict; one row per person
    # and role, author beats reviewer, first thread by rank writes it.
    def rebuild_credits!(commit_ids)
      CommitPerson.llm.where(commit_id: commit_ids).delete_all
      verdicts = current_verdicts(commit_ids)
      return if verdicts.empty?

      parsed = CommitPerson.parsed.where(commit_id: commit_ids).to_a.group_by(&:commit_id)
      wanted = verdicts.flat_map { |v| [ v.source_message_id, v.author_message_id ] + llm_suggestions(v).map { |r| r["reviewer_message_id"] } }
      messages = Message.where(id: wanted.compact.uniq).includes(:sender).index_by(&:id)
      rows = verdicts.group_by(&:commit_id).flat_map do |commit_id, list|
        credits_for(commit_id, list, parsed.fetch(commit_id, []), messages)
      end
      CommitPerson.insert_all(rows) if rows.any?
    end

    def current_verdicts(commit_ids)
      others = CommitVerdict.where(commit_id: commit_ids).where.not(topic_id: @run.topic_id).select(:topic_id)
      runs = PatchsetRun.done.where(topic_id: others)
                        .select("DISTINCT ON (topic_id) id").order(:topic_id, created_at: :desc, id: :desc)
      list = CommitVerdict.where(patchset_run_id: runs.map(&:id) << @run.id, commit_id: commit_ids,
                                 verdict: CommitVerdict::COMMITTED, confidence: @threshold..).to_a
      rank = ThreadRank.order(list.map(&:topic_id).uniq).each_with_index.to_h
      list.sort_by { |v| [ rank[v.topic_id], v.id ] }
    end

    def llm_suggestions(v)
      Array(v.reviews).select { |r| r["source"] == "llm" && r["confidence"].to_f >= @threshold }
    end

    # The author the model named wins, then the sender of the source patchset
    # (so from_discussion needs a named author); parsed rows beat both, and
    # a parsed co-author counts as one. Reviewers: sender of
    # reviewer_message_id, then a name match among the thread's senders, then
    # the bare name; nobody already credited on the commit gets a second row.
    def credits_for(commit_id, verdicts, parsed, messages)
      authors = []
      unless parsed.any? { |p| %w[author co_author].include?(p.role) }
        verdicts.each do |v|
          person = author_of(v, messages) or next
          next if authors.any? { |a| same_person?(a, person) }

          authors << person.merge(commit_id: commit_id, topic_id: v.topic_id, role: "author", source: "llm", confidence: v.confidence)
        end
      end
      taken = parsed.map { |p| { person_id: p.person_id, raw_name: p.raw_name } } + authors
      reviewers = verdicts.flat_map do |v|
        llm_suggestions(v).filter_map do |r|
          person = (message = messages[r["reviewer_message_id"]]) ? sender_of(message) : named_person(r["reviewer"], v.topic_id)
          next if taken.any? { |p| same_person?(p, person) }

          person.merge(commit_id: commit_id, topic_id: v.topic_id, role: "reviewer", source: "llm", confidence: r["confidence"].to_f)
        end
      end
      reviewers = reviewers.group_by { |row| row[:person_id] || row[:raw_name].downcase }
                           .values.map { |dups| dups.max_by.with_index { |row, i| [ row[:confidence], -i ] } }
      authors + reviewers
    end

    def same_person?(a, b)
      (b[:person_id] && a[:person_id] == b[:person_id]) || a[:raw_name].to_s.strip.casecmp?(b[:raw_name].to_s.strip)
    end

    def author_of(v, messages)
      if (message = messages[v.author_message_id])
        sender_of(message)
      elsif v.author_name.present?
        named_person(v.author_name, v.topic_id)
      elsif (message = messages[v.source_message_id])
        sender_of(message)
      end
    end

    def sender_of(message)
      { person_id: message.sender_person_id, raw_name: message.sender.name, raw_email: message.sender.email }
    end

    def named_person(name, topic_id)
      matches = senders_by_name(topic_id).fetch(name.strip.downcase, [])
      if matches.map(&:last).uniq.one?
        found, email, person_id = matches.first
        { person_id: person_id, raw_name: found, raw_email: email }
      else
        { person_id: nil, raw_name: name.strip, raw_email: nil }
      end
    end

    def senders_by_name(topic_id)
      (@senders_by_name ||= {})[topic_id] ||= Message.where(topic_id: topic_id).joins(:sender)
        .joins("LEFT JOIN people ON people.id = messages.sender_person_id")
        .joins("LEFT JOIN aliases display ON display.id = people.default_alias_id")
        .distinct.pluck("aliases.name", "aliases.email", "display.name", "display.email", "messages.sender_person_id")
        .flat_map { |name, email, dname, demail, pid| [ [ name, email, pid ], [ dname, demail, pid ] ] }
        .select(&:first).uniq.group_by { |n, _, _| n.strip.downcase }
    end

    def close_rechecks!(known)
      ids = recheck_shas.filter_map { |s| known[s]&.id }
      LineageRecheck.open.where(topic_id: @run.topic_id, commit_id: ids).update_all(done_at: Time.current) if ids.any?
    end

    # a partner thread judged the same commit without seeing this verdict
    def open_rechecks!(judged, known)
      now = Time.current
      rows = judged.select { |v| CommitVerdict::COMMITTED.include?(v["verdict"]) }.flat_map do |v|
        family = family_shas(known[v["sha"]])
        partner_verdicts(family.keys).filter_map do |pv|
          next if saw?(pv.patchset_run, family[pv.commit_id], v)

          { topic_id: pv.topic_id, commit_id: pv.commit_id, requested_by_run_id: @run.id, created_at: now }
        end
      end
      rows = rows.uniq { |r| r.values_at(:topic_id, :commit_id) }
      LineageRecheck.insert_all(rows, unique_by: :index_lineage_rechecks_open) if rows.any?
    end

    def family_shas(commit)
      canonical = commit.cherry_picked_from_sha || commit.sha
      Commit.where(sha: canonical).or(Commit.where(cherry_picked_from_sha: canonical)).pluck(:id, :sha).to_h
    end

    def partner_verdicts(commit_ids)
      topics = CommitTopic.trailer.where(commit_id: commit_ids).where.not(topic_id: @run.topic_id).select(:topic_id)
      runs = PatchsetRun.done.where(topic_id: topics)
                        .select("DISTINCT ON (topic_id) id").order(:topic_id, created_at: :desc, id: :desc)
      CommitVerdict.where(patchset_run_id: runs, commit_id: commit_ids, verdict: CommitVerdict::COMMITTED)
                   .joins(:topic).merge(Topic.active).includes(:patchset_run)
    end

    def saw?(partner_run, sha, v)
      cand = Array(partner_run.bundle_index&.dig("candidates"))
             .find { |c| c["sha"] == sha || Array(c["backports"]).include?(sha) }
      seen = Array(cand&.dig("other_threads")).find { |t| t["topic_id"] == @run.topic_id }
      seen.present? && seen["verdict"] == v["verdict"] && seen["source_message_id"] == v["source_message_id"]
    end

    def backport_ids(judged)
      shas = judged.to_h { |v| [ v["sha"], candidates.dig(v["sha"], "backports") || [] ] }
      ids = Commit.where(sha: shas.values.flatten).pluck(:sha, :id).to_h
      shas.transform_values { |list| list.filter_map { |s| ids[s] } }
    end
  end
end
