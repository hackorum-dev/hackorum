class Attachment < ApplicationRecord
  belongs_to :message
  has_many :patch_files, dependent: :destroy

  after_create :mark_topic_has_attachments
  after_destroy :update_topic_has_attachments

  def patch?
    file_name&.ends_with?(".patch") || file_name&.ends_with?(".diff") || patch_content?
  end

  def patch_extension?
    file_name&.ends_with?(".patch") || file_name&.ends_with?(".diff")
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

  def update_topic_has_attachments
    topic = message&.topic
    return unless topic

    has_any = topic.attachments.exists?
    topic.update_column(:has_attachments, has_any) if topic.has_attachments? != has_any
  end
end
