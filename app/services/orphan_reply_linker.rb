# frozen_string_literal: true

# Mail can arrive child first. The child then starts its own topic, with the
# parent's Message-ID kept in reply_to_message_id. This joins the two once the
# parent exists.
class OrphanReplyLinker
  def self.orphans_of(parent)
    return Message.none if parent.message_id.blank?

    Message.where(reply_to_message_id: parent.message_id, reply_to_id: nil).where.not(id: parent.id)
  end

  def self.adopt_for(parent)
    orphans_of(parent).order(:id).select { |child| link(child, parent) }
  end

  def self.link(child, parent)
    return false if child.id == parent.id || descends_from?(parent, child)

    Message.transaction(requires_new: true) do
      child.update_columns(reply_to_id: parent.id)
      merge_topics!(child.topic_id, parent.topic_id) if child.topic_id != parent.topic_id
    end
    true
  rescue StandardError => e
    Rails.logger.error("OrphanReplyLinker: message #{child.id} -> #{parent.id} failed: #{e.class}: #{e.message}")
    false
  end

  def self.descends_from?(message, ancestor)
    seen = Set.new
    current_id = message.reply_to_id
    while current_id && seen.add?(current_id)
      return true if current_id == ancestor.id

      current_id = Message.where(id: current_id).pick(:reply_to_id)
    end
    false
  end

  def self.merge_topics!(source_id, target_id)
    result = TopicMergeService.new(
      source_topic: Topic.find(source_id),
      target_topic: Topic.find(target_id),
      merged_by: nil,
      automatic: true,
      merge_reason: "Parent message arrived after its reply"
    ).call
    raise TopicMergeService::Error, result.error unless result.success?
  end
  private_class_method :merge_topics!
end
