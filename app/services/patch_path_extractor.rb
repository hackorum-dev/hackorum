require "zlib"

class PatchPathExtractor
  DIFF_PATH_PATTERNS = [
    /^diff --git a\/(\S+) b\/\S+/,
    /^Index: (\S+)/,
    /^\+\+\+ (\S+)/,
    /^--- (\S+)/,
    /^\*\*\* (\S+)/
  ].freeze

  # bare "--- " lines happen in prose; demand real diff structure
  INLINE_DIFF_RE = /(?:\A|\n)(?:diff --git |Index: |\*\*\* .*\n--- .*\n\*{4}|--- .*\n\+\+\+ )/

  PATCHISH_NAME_RE = /\.(patch|diff|gz)/i
  PATCHISH_TYPE_RE = /diff|patch/i
  GZIP_NAME_RE = /\.(gz|tgz)\z/i

  # keep in sync with INLINE_DIFF_RE
  INLINE_DIFF_SQL_RE = '(^|\n)(diff --git |Index: |\*\*\* .*\n--- .*\n\*\*\*\*|--- .*\n\+\+\+ )'

  def self.call(message)
    new(message).paths
  end

  def self.backfill(from:, to:, io: $stderr)
    scope = Message.where(created_at: from..to)
    candidates = scope.where(id: Attachment.where(
                    "file_name ~* ? OR content_type ~* ?",
                    PATCHISH_NAME_RE.source, PATCHISH_TYPE_RE.source).select(:message_id))
                      .or(scope.where(is_patch_submission: true))
                      .or(scope.where("body ~ ?", INLINE_DIFF_SQL_RE))
    total = candidates.count
    done = 0
    candidates.find_each(batch_size: 200) do |msg|
      begin
        msg.recompute_patch_paths!
      rescue StandardError
        io.puts("backfill: failed message #{msg.id}")
        raise
      end
      done += 1
      io.puts("backfill: #{done}/#{total}") if (done % 500).zero?
    end
    io.puts("backfill: done #{done}/#{total}")
  end

  def self.paths_from_text(text)
    bin = text.dup.force_encoding(Encoding::BINARY)
    raw = DIFF_PATH_PATTERNS.flat_map { |re| bin.scan(re) }.flatten
    raw.filter_map { |p| normalize(p) }.uniq
  end

  def self.normalize(path)
    p = path.dup.force_encoding(Encoding::UTF_8)
    p = p.scrub("?")
    p = p.sub(%r{\A[ab]/}, "").sub(%r{\A\./}, "")
    if (m = p.match(%r{(?:\A|/)((?:src|contrib|doc|config)/.*)\z}))
      p = m[1]
    end
    return nil if p == "/dev/null" || p.empty?
    return nil unless p.match?(%r{[/.]})
    return nil if p.match?(/\A\d+(,\d+)?\z/)
    p
  end
  private_class_method :normalize

  def initialize(message)
    @message = message
  end

  def paths
    texts = attachment_texts
    body = @message.body.to_s.b
    texts << body if body.match?(INLINE_DIFF_RE)
    texts.flat_map { |t| self.class.paths_from_text(t) }.uniq
  end

  private

  def attachment_texts
    @message.attachments.filter_map do |att|
      next unless patchish?(att)
      decode(att)
    end
  end

  def patchish?(att)
    att.patch_submission_candidate? ||
      att.file_name.to_s.match?(PATCHISH_NAME_RE) ||
      att.content_type.to_s.match?(PATCHISH_TYPE_RE)
  end

  def decode(att)
    raw = att.decoded_body
    return nil if raw.nil?
    if att.file_name.to_s.match?(GZIP_NAME_RE)
      raw = Zlib::GzipReader.new(StringIO.new(raw)).read(PatchBranches::PatchsetExtractor::MAX_DECOMPRESSED + 1).to_s
      return nil if raw.bytesize > PatchBranches::PatchsetExtractor::MAX_DECOMPRESSED
    end
    raw.force_encoding(Encoding::BINARY)
  rescue StandardError => e
    Rails.logger.warn("PatchPathExtractor: attachment #{att.id} undecodable: #{e.class}")
    nil
  end
end
