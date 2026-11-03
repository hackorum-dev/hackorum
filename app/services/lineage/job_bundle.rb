require "digest"
require "fileutils"
require "json"

module Lineage
  class JobBundle
    PROMPT_PATH = Rails.root.join("config/lineage/prompt.md")
    SCHEMA_PATH = Rails.root.join("config/lineage/result.schema.json")
    QUOTE_RE = /\A>/
    ORIGINAL_RE = /\A-----Original Message-----/
    ATTRIBUTION_START_RE = /\A\s*On .{0,200}\s*\z/
    ATTRIBUTION_END_RE = /\A.{0,200}wrote:\s*\z/
    ATTRIBUTION_RE = /\A\s*On .{0,200}wrote:\s*\z/
    MODE_SECTION_RE = %r{^<!-- (full|trailer) -->\n(.*?)^<!-- /\1 -->\n}m

    def self.prompt_version = Digest::SHA256.hexdigest(File.read(PROMPT_PATH))[0, 12]

    def initialize(run:, topic:, patchsets:, candidates:, pairs:, commit_scores:, branches:, previous:, repo_path:, mode:)
      @run = run
      @topic = topic
      @patchsets = patchsets
      @candidates = candidates
      @pairs = pairs
      @commit_scores = commit_scores
      @branches = branches
      @previous = previous
      @repo_path = repo_path.to_s
      @mode = mode
    end

    def write(dir)
      messages = @topic.messages.includes(:sender, :attachments, sender_person: :default_alias).order(:created_at, :id).to_a
      write_messages(dir, messages)
      write_commits(dir)
      File.write(File.join(dir, "index.json"), JSON.pretty_generate(index(messages)))
      File.write(File.join(dir, "pairs.json"), JSON.generate(@pairs.map { |p| p.transform_keys(&:to_s) }))
      File.write(File.join(dir, "commit_scores.json"), JSON.generate(@commit_scores.map { |s| s.transform_keys(&:to_s) }))
      File.write(File.join(dir, "README.md"), readme(messages))
      messages.last&.id
    end

    private

    def index(messages)
      by_id = messages.index_by(&:id)
      {
        "topic" => { "id" => @topic.id, "title" => @topic.title,
                     "lists" => @topic.mailing_lists.map(&:identifier),
                     "message_count" => messages.size },
        "repo_path" => @repo_path,
        "mode" => @mode,
        "through_message_id" => messages.last&.id,
        "patchsets" => @patchsets.map { |p| patchset_entry(p, by_id) },
        "candidates" => @candidates.map { |c| candidate_entry(c) },
        "previous" => @previous
      }
    end

    def patchset_entry(p, by_id)
      entry = {
        "ordinal" => p.ordinal, "message_id" => p.message.id,
        "date" => p.message.created_at.iso8601, "sender" => (by_id[p.message.id] || p.message).sender_display_alias&.name,
        "dir" => "patchsets/#{format('%03d', p.ordinal)}",
        "files" => p.files.map { |f| File.basename(f) },
        "subjects" => p.parsed&.subjects || [],
        "changed_paths" => p.parsed&.files&.map(&:path) || [],
        "parse_error" => p.parse_error,
        "nocfbot" => p.nocfbot,
        "nocfbot_files" => p.message.attachments.select(&:nocfbot?).map { |a|
          File.basename(a.file_name).sub(PatchBranches::PatchsetExtractor::WRAPPER_SUFFIX, "")
        }
      }
      branch = @branches[p.message.id]
      entry["branch"] = branch.transform_keys(&:to_s) if branch
      entry
    end

    def candidate_entry(c)
      commit = c[:entry].commit
      { "sha" => commit.sha, "subject" => commit.subject, "committed_at" => commit.committed_at.iso8601,
        "committer" => commit.committer_name, "origin" => c[:origin],
        "diff_available" => c[:entry].available,
        "backports" => Array(c[:backports]).map(&:sha), "reviewers" => c[:reviewers] || [],
        "overlap" => c[:overlap]&.transform_keys(&:to_s) }
    end

    def write_messages(dir, messages)
      mdir = File.join(dir, "messages")
      FileUtils.mkdir_p(mdir)
      set_by_id = @patchsets.index_by { |p| p.message.id }
      messages.each_with_index do |m, i|
        ordinal = i + 1
        header = [
          "Message: ##{ordinal} (id #{m.id})",
          "From: #{m.sender_display_alias&.name} <#{m.sender&.email}>",
          "Date: #{m.created_at.iso8601}",
          "Subject: #{m.subject}"
        ]
        header << "Patchset: patchsets/#{format('%03d', ordinal)}" if set_by_id[m.id]
        header << "Attachments: #{m.attachments.map(&:file_name).join(', ')}" if m.attachments.any?
        File.write(File.join(mdir, format("%03d.txt", ordinal)), header.join("\n") + "\n\n" + strip_quotes(m.body))
      end
    end

    def strip_quotes(body)
      lines = []
      all = body.to_s.scrub.lines
      all.each_with_index do |l, i|
        break if l.match?(ORIGINAL_RE)
        next if l.match?(QUOTE_RE) || l.match?(ATTRIBUTION_RE)
        next if l.match?(ATTRIBUTION_START_RE) && all[i + 1]&.match?(ATTRIBUTION_END_RE)
        next if i > 0 && all[i - 1].match?(ATTRIBUTION_START_RE) && l.match?(ATTRIBUTION_END_RE)
        lines << l
      end
      lines.join.gsub(/\n{3,}/, "\n\n")
    end

    def write_commits(dir)
      @candidates.each do |c|
        entry = c[:entry]
        next unless entry.available
        cdir = File.join(dir, "commits", entry.commit.sha)
        FileUtils.mkdir_p(cdir)
        File.write(File.join(cdir, "message.txt"), entry.message_text)
        File.binwrite(File.join(cdir, "diff.patch"), entry.diff_text)
      end
    end

    def readme(messages)
      File.read(PROMPT_PATH)
          .gsub(MODE_SECTION_RE) { Regexp.last_match(1) == @mode ? Regexp.last_match(2) : "" }
          .gsub("{{mode}}") { @mode }
          .gsub("{{run_id}}") { @run.id.to_s }
          .gsub("{{topic_id}}") { @topic.id.to_s }
          .gsub("{{title}}") { @topic.title.to_s }
          .gsub("{{message_count}}") { messages.size.to_s }
          .gsub("{{patchset_count}}") { @patchsets.size.to_s }
          .gsub("{{candidate_count}}") { @candidates.size.to_s }
          .gsub("{{repo_path}}") { @repo_path }
    end
  end
end
