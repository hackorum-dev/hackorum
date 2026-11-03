require "fileutils"

module Lineage
  class PatchsetEnumerator
    Patchset = Struct.new(:message, :ordinal, :dir, :files, :parsed, :parse_error, :nocfbot, keyword_init: true)

    def initialize(topic)
      @topic = topic
    end

    def call(dir)
      ids = @topic.chronological_message_ids
      messages = @topic.messages.where(id: Attachment.select(:message_id))
                       .includes(:attachments).order(:created_at, :id)
                       .select { |m| m.attachments.any?(&:lineage_patch_candidate?) }
      messages.map do |message|
        nocfbot = message.attachments.none?(&:patch_submission_candidate?)
        ordinal = ids.index(message.id) + 1
        sub = File.join(dir, format("%03d", ordinal))
        FileUtils.mkdir_p(sub)
        # the branch applied by CI tooling excludes nocfbot files on purpose
        files = PatchBranches::PatchsetExtractor.new(message, include_nocfbot: true).extract(sub)
        Patchset.new(message: message, ordinal: ordinal, dir: sub, files: files,
                     parsed: DiffParser.parse_files(files), parse_error: nil, nocfbot: nocfbot)
      rescue PatchBranches::PatchsetExtractor::Error => e
        Patchset.new(message: message, ordinal: ordinal, dir: sub, files: [], parsed: nil,
                     parse_error: "#{e.class}: #{e.message}", nocfbot: nocfbot)
      end
    end
  end
end
