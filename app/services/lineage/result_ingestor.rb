require "json"

module Lineage
  class ResultIngestor
    Error = Class.new(StandardError)

    LEVELLED = %w[modified partial].freeze
    SUGGESTED_COVERAGES = %w[final earlier].freeze
    NOT_ASSESSED = { "reviewed_message_ids" => [], "coverage" => "none", "note" => "not assessed", "source" => "trailer" }.freeze

    def initialize(run:, index:, link_threshold: 0.8, link: true, mode: nil)
      @run = run
      @index = index
      @threshold = link_threshold
      @link = link
      @mode = mode
      @suggestions = {}
    end

    def call(result_path)
      data = parse(result_path)
      validate!(data)
      @notes = []
      @suggestions = {}
      extras = dedupe_extras(data)
      found = Commit.where(sha: extras.map { |v| v["sha"] }).index_by(&:sha)
      extras, missing = extras.partition { |v| found.key?(v["sha"]) }
      known = candidate_commits.merge(found)
      missing.each { |v| @notes << "extra commit not in commits table: #{v['sha']}" }
      @ref_shas = reference_shas(data, known)
      PatchsetRun.transaction do
        @run.lineages.delete_all
        @run.verdicts.delete_all
        PatchsetLineage.insert_all(lineage_rows(data))
        CommitVerdict.insert_all(verdict_rows(data["verdicts"], known, extra: false) +
                                 verdict_rows(extras, known, extra: true))
        @run.finish!(status: "done", story: normalize(story_text(data)), raw_result: data,
                     error: @notes.join("\n").presence)
        judged = data["verdicts"] + extras
        if @link && judged.any?
          previously_linked = CommitTopic.llm.where(topic_id: @run.topic_id).pluck(:commit_id)
          link!(judged, known)
          CommitPerson.llm.where(commit_id: judged.map { |v| known[v["sha"]].id } | previously_linked).delete_all
          authors = attribute_authors!(judged, known)
          attribute_reviewers!(judged, known, authors)
        end
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

    def validate!(data)
      raise Error, "top level must be an object with lineage, verdicts, story" unless data.is_a?(Hash) &&
        data["lineage"].is_a?(Array) && data["verdicts"].is_a?(Array) && story_shape?(data["story"])
      raise Error, "extra_commits must be an array" unless extras(data).is_a?(Array)
      if @mode == "lineage" && (data["verdicts"].any? || extras(data).any?)
        raise Error, "lineage mode allows no verdicts or extra_commits"
      end

      seen = Set.new
      data["lineage"].each do |l|
        raise Error, "lineage entry must be an object" unless l.is_a?(Hash)
        id = l["message_id"]
        raise Error, "unknown message id #{id}" unless patchset_ids.include?(id)
        raise Error, "duplicate lineage for #{id}" unless seen.add?(id)
        parent = l["parent_message_id"]
        raise Error, "unknown parent #{parent} for #{id}" unless parent.nil? || patchset_ids.include?(parent)
        raise Error, "message #{id} cannot be its own parent" if parent == id
        raise Error, "bad step_kind #{l['step_kind']}" unless PatchsetLineage::STEP_KINDS.include?(l["step_kind"])
        check_confidence!(l["confidence"], "lineage #{id}")
      end
      missing = patchset_ids - seen
      raise Error, "lineage missing for message #{missing.first}" if missing.any?

      shas = Set.new
      data["verdicts"].each do |v|
        raise Error, "verdict entry must be an object" unless v.is_a?(Hash)
        raise Error, "unknown sha #{v['sha']}" unless candidate_commits.key?(v["sha"])
        raise Error, "duplicate verdict for #{v['sha']}" unless shas.add?(v["sha"])
        raise Error, "bad verdict #{v['verdict']}" unless CommitVerdict::VERDICTS.include?(v["verdict"])
        check_verdict!(v, "verdict #{v['sha']}")
      end

      extras(data).each do |v|
        raise Error, "extra commit entry must be an object" unless v.is_a?(Hash)
        raise Error, "bad sha #{v['sha'].inspect} for extra commit" unless v["sha"].is_a?(String)
        raise Error, "bad verdict #{v['verdict']} for extra commit #{v['sha']}" unless CommitVerdict::COMMITTED.include?(v["verdict"])
        check_verdict!(v, "extra commit #{v['sha']}")
      end
    end

    def check_verdict!(v, what)
      src = v["source_message_id"]
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
        check_reviewed_ids!(r["reviewed_message_ids"], what)
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
        check_reviewed_ids!(r["reviewed_message_ids"], what)
        check_confidence!(r["confidence"], "suggested reviewer #{r['reviewer']} in #{what}")
      end
    end

    def check_reviewed_ids!(ids, what)
      raise Error, "reviewed_message_ids must be an array for #{what}" unless ids.is_a?(Array)
      ids.each { |id| raise Error, "unknown reviewed message #{id} for #{what}" unless patchset_ids.include?(id) }
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

      @suggestions[v["sha"]] = list.uniq { |r| r["reviewer"].squish.downcase }.map do |r|
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
      CommitTopic.llm.where(topic_id: @run.topic_id).where.not(commit_id: ids).delete_all
    end

    # The author the model named wins, then the sender of the source patchset
    # (so from_discussion needs a named author); parsed rows beat both.
    def attribute_authors!(judged, known)
      eligible = credited(judged).select { |v| v["source_message_id"] || v["author_message_id"] || v["author_name"] }
      return [] if eligible.empty?

      ids = eligible.map { |v| known[v["sha"]].id }
      authored = CommitPerson.parsed.where(commit_id: ids, role: "author").distinct.pluck(:commit_id).to_set
      wanted = eligible.flat_map { |v| [ v["source_message_id"], v["author_message_id"] ] }.compact
      messages = Message.where(id: wanted).includes(:sender).index_by(&:id)
      rows = eligible.filter_map do |v|
        commit_id = known[v["sha"]].id
        next if authored.include?(commit_id)

        author = author_of(v, messages) or next
        author.merge(commit_id: commit_id, role: "author", source: "llm", confidence: v["confidence"].to_f)
      end
      CommitPerson.insert_all(rows) if rows.any?
      rows
    end

    def credited(judged)
      judged.select { |v| CommitVerdict::COMMITTED.include?(v["verdict"]) && v["confidence"].to_f >= @threshold }
    end

    # sender of reviewer_message_id, then a name match among the thread's
    # senders, then the bare name; nobody already credited on the commit gets a second row
    def attribute_reviewers!(judged, known, authors)
      wanted = credited(judged).flat_map do |v|
        @suggestions.fetch(v["sha"], []).select { |r| r["confidence"] >= @threshold }.map { |r| [ known[v["sha"]].id, r ] }
      end
      return if wanted.empty?

      taken = CommitPerson.parsed.where(commit_id: wanted.map(&:first).uniq)
                          .map { |p| { commit_id: p.commit_id, person_id: p.person_id, raw_name: p.raw_name } }
                          .concat(authors).group_by { |p| p[:commit_id] }
      messages = Message.where(id: wanted.filter_map { |_, r| r["reviewer_message_id"] }).includes(:sender).index_by(&:id)
      rows = wanted.filter_map do |commit_id, r|
        person = (message = messages[r["reviewer_message_id"]]) ? sender_of(message) : named_person(r["reviewer"])
        next if taken.fetch(commit_id, []).any? { |p| same_person?(p, person) }

        person.merge(commit_id: commit_id, role: "reviewer", source: "llm", confidence: r["confidence"])
      end
      rows = rows.group_by { |row| [ row[:commit_id], row[:person_id] || row[:raw_name].downcase ] }
                 .values.map { |dups| dups.max_by { |row| row[:confidence] } }
      CommitPerson.insert_all(rows) if rows.any?
    end

    def same_person?(a, b)
      (b[:person_id] && a[:person_id] == b[:person_id]) || a[:raw_name].to_s.strip.casecmp?(b[:raw_name].to_s.strip)
    end

    def author_of(v, messages)
      if (message = messages[v["author_message_id"]])
        sender_of(message)
      elsif v["author_name"].present?
        named_person(v["author_name"])
      elsif (message = messages[v["source_message_id"]])
        sender_of(message)
      end
    end

    def sender_of(message)
      { person_id: message.sender_person_id, raw_name: message.sender.name, raw_email: message.sender.email }
    end

    def named_person(name)
      matches = senders_by_name.fetch(name.strip.downcase, [])
      if matches.map(&:last).uniq.one?
        found, email, person_id = matches.first
        { person_id: person_id, raw_name: found, raw_email: email }
      else
        { person_id: nil, raw_name: name.strip, raw_email: nil }
      end
    end

    def senders_by_name
      @senders_by_name ||= Message.where(topic_id: @run.topic_id).joins(:sender)
        .joins("LEFT JOIN people ON people.id = messages.sender_person_id")
        .joins("LEFT JOIN aliases display ON display.id = people.default_alias_id")
        .distinct.pluck("aliases.name", "aliases.email", "display.name", "display.email", "messages.sender_person_id")
        .flat_map { |name, email, dname, demail, pid| [ [ name, email, pid ], [ dname, demail, pid ] ] }
        .select(&:first).uniq.group_by { |n, _, _| n.strip.downcase }
    end

    def backport_ids(judged)
      shas = judged.to_h { |v| [ v["sha"], candidates.dig(v["sha"], "backports") || [] ] }
      ids = Commit.where(sha: shas.values.flatten).pluck(:sha, :id).to_h
      shas.transform_values { |list| list.filter_map { |s| ids[s] } }
    end
  end
end
