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
    MODE_SECTION_RE = %r{^<!-- ([a-z ]+) -->\n(.*?)^<!-- /\1 -->\n}m

    def self.prompt_version = Digest::SHA256.hexdigest(File.read(PROMPT_PATH))[0, 12]

    def initialize(run:, topic:, patchsets:, candidates:, pairs:, branches:, previous:, mode:,
                   base_run: nil, new_patchset_ids: nil)
      @run = run
      @topic = topic
      @patchsets = patchsets
      @candidates = candidates
      @pairs = pairs
      @branches = branches
      @previous = previous
      @mode = mode
      @base_run = base_run
      @new_patchset_ids = new_patchset_ids
    end

    def write(dir)
      messages = @topic.messages.includes(:sender, :attachments, sender_person: :default_alias).order(:created_at, :id).to_a
      write_messages(dir, messages)
      File.write(File.join(dir, "index.json"), JSON.pretty_generate(index(messages)))
      File.write(File.join(dir, "pairs.json"), JSON.generate(@pairs.map { |p| p.transform_keys(&:to_s) }))
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
        "mode" => @mode,
        "through_message_id" => messages.last&.id,
        "patchsets" => @patchsets.map { |p| patchset_entry(p, by_id) },
        "candidates" => @candidates.map { |c| candidate_entry(c) },
        "previous" => @previous
      }.merge(update_keys(messages))
    end

    # update runs: what is new since the base run
    def update_keys(messages)
      return {} unless @base_run

      { "since_message_id" => @base_run.through_message_id,
        "new_message_ordinals" => messages.each_with_index.filter_map { |m, i| i + 1 if Updates.new_message?(@base_run, m) } }
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
      entry["new"] = @new_patchset_ids.include?(p.message.id) if @base_run
      branch = @branches[p.message.id]
      entry["branch"] = branch.transform_keys(&:to_s) if branch
      entry
    end

    def candidate_entry(c)
      commit = c[:commit]
      { "sha" => commit.sha, "subject" => commit.subject, "committed_at" => commit.committed_at.iso8601,
        "committer" => commit.committer_name, "origin" => c[:origin],
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

    def readme(messages)
      resolve_modes(File.read(PROMPT_PATH))
          .gsub("{{mode}}") { @mode }
          .gsub("{{run_id}}") { @run.id.to_s }
          .gsub("{{topic_id}}") { @topic.id.to_s }
          .gsub("{{title}}") { @topic.title.to_s }
          .gsub("{{message_count}}") { messages.size.to_s }
          .gsub("{{patchset_count}}") { @patchsets.size.to_s }
          .gsub("{{candidate_count}}") { @candidates.size.to_s }
    end

    # outer sections first, then the ones they contained
    def resolve_modes(text)
      loop do
        out = text.gsub(MODE_SECTION_RE) { Regexp.last_match(1).split.include?(@mode) ? Regexp.last_match(2) : "" }
        return out if out == text
        text = out
      end
    end
  end
end
