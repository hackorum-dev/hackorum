module DraftSidebarLoader
  extend ActiveSupport::Concern

  private

  def load_sidebar_drafts(topic)
    numbers = topic.messages.order(:created_at).pluck(:id)
                            .each_with_index.to_h { |id, i| [ id, i + 1 ] }
    drafts = current_user.outgoing_drafts
                         .where.not(status: OutgoingDraft::STATUS_SENT)
                         .where(topic_id: topic.id)
                         .includes(reply_to_message: { sender_person: :default_alias })
                         .to_a
                         .sort_by { |d| numbers[d.reply_to_message_id] || Float::INFINITY }
    [ drafts, numbers ]
  end
end
