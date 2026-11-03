class Attachment < ApplicationRecord
  belongs_to :message

  PATCH_SUBMISSION_BASE_EXTS    = %w[patch diff diffs].freeze
  PATCH_SUBMISSION_WRAPPER_EXTS = [ "", ".gz", ".bz2", ".txt" ].freeze
  PATCH_SUBMISSION_EXTENSIONS   = PATCH_SUBMISSION_BASE_EXTS.flat_map { |b|
    PATCH_SUBMISSION_WRAPPER_EXTS.map { |w| ".#{b}#{w}" }
  }.freeze
  PATCH_SUBMISSION_EXCLUDE_PATTERNS = %w[nocfbot no_cfbot].freeze
  PATCH_SUBMISSION_EXCLUDE_REGEX = Regexp.union(PATCH_SUBMISSION_EXCLUDE_PATTERNS).freeze
  PATCH_SUBMISSION_CONTENT_TYPES = %w[text/x-diff text/x-patch application/x-patch].freeze
  # Matches the historical pg-hackers naming conventions the extension list misses:
  # bare basenames like /bjm/diff, /rtmp/diff, "patch"; numeric suffix like foo.patch.3.
  PATCH_SUBMISSION_FILENAME_REGEX = %r{
    (?:\A|/)(?:patch|diff)\z
    |
    \.(?:patch|diff|diffs)(?:\.\d+)?\z
  }ix.freeze

  after_create :mark_topic_has_attachments
  after_destroy :update_topic_has_attachments
  after_save :recompute_message_patch_submission
  after_destroy :recompute_message_patch_submission

  # This list is in no way comprehensive. It can be extended as needed.
  TEXT_APPLICATION_TYPES = %w[
    application/json
    application/sql
    application/x-perl
    application/x-python
    application/x-ruby
    application/x-sh
    application/x-shellscript
    application/xml
    application/yaml
  ].freeze

  def text?
    return true if content_type&.start_with?("text/")
    return true if content_type&.end_with?("+xml", "+json")
    TEXT_APPLICATION_TYPES.include?(content_type)
  end

  def patch?
    patch_extension? || patch_content?
  end

  def patch_extension?
    file_name&.ends_with?(".patch", ".diff")
  end

  def patch_submission_candidate?
    lineage_patch_candidate? && !nocfbot?
  end

  def nocfbot?
    return false if file_name.blank?
    name_lower = file_name.downcase
    PATCH_SUBMISSION_EXCLUDE_PATTERNS.any? { |p| name_lower.include?(p) }
  end

  def lineage_patch_candidate?
    return false if file_name.blank?
    return true if nocfbot? && patch_content?
    name_lower = file_name.downcase.sub(/[._-]*#{PATCH_SUBMISSION_EXCLUDE_REGEX}\z/, "")
    return true if PATCH_SUBMISSION_EXTENSIONS.any? { |ext| name_lower.end_with?(ext) }
    return true if name_lower.match?(PATCH_SUBMISSION_FILENAME_REGEX)
    PATCH_SUBMISSION_CONTENT_TYPES.any? { |ct| content_type&.downcase&.start_with?(ct) }
  end

  def decoded_body
    Base64.decode64(body) if body.present?
  end

  def decoded_body_utf8
    raw = decoded_body
    return unless raw

    utf8 = raw.dup
    utf8.force_encoding("UTF-8")
    return utf8 if utf8.valid_encoding?

    raw.encode("UTF-8", invalid: :replace, undef: :replace, replace: "\uFFFD")
  end

  def diff_line_stats
    return { added: 0, removed: 0 } unless patch?
    return @diff_line_stats if defined?(@diff_line_stats)

    text = decoded_body_utf8
    return @diff_line_stats = { added: 0, removed: 0 } unless text.present?

    added = 0
    removed = 0

    text.each_line do |line|
      if line.start_with?("+") && !line.start_with?("+++")
        added += 1
      elsif line.start_with?("-") && !line.start_with?("---")
        removed += 1
      elsif line.start_with?("> ")
        added += 1
      elsif line.start_with?("< ")
        removed += 1
      elsif line.start_with?("! ")
        added += 1
        removed += 1
      end
    end

    @diff_line_stats = { added: added, removed: removed }
  end

  private

  def patch_content?
    decoded_body&.starts_with?("diff ") ||
    decoded_body&.starts_with?("--- ") ||
    decoded_body&.starts_with?("*** ") ||
    decoded_body&.starts_with?("Index:") ||
    decoded_body&.include?("@@") ||
    decoded_body&.include?("***************")
  end

  def mark_topic_has_attachments
    topic = message&.topic
    return unless topic

    topic.update_column(:has_attachments, true) unless topic.has_attachments?
  end

  def recompute_message_patch_submission
    message&.recompute_patch_submission!
    message&.recompute_patch_paths!
  end

  def update_topic_has_attachments
    topic = message&.topic
    return unless topic

    has_any = topic.attachments.exists?
    topic.update_column(:has_attachments, has_any) if topic.has_attachments? != has_any
  end
end
