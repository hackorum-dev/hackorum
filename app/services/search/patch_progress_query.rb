# frozen_string_literal: true

module Search
  class PatchProgressQuery
    def initialize(from_ids: nil, after_ids: nil, waiting: false, waiting_before: nil)
      @from_ids = from_ids
      @after_ids = after_ids
      @waiting = waiting
      @waiting_before = waiting_before
    end

    def relation
      scope = Message.where(is_patch_submission: true)
      scope = scope.where(sender_person_id: @from_ids) if @from_ids
      scope = after(scope) if @after_ids
      scope = waiting(scope) if @waiting
      scope.select(:topic_id)
    end

    private

    def after(scope)
      scope.where(<<~SQL.squish, @after_ids)
        EXISTS (SELECT 1 FROM topic_participants tp
                WHERE tp.topic_id = messages.topic_id AND tp.person_id IN (?)
                  AND messages.created_at > tp.last_message_at)
      SQL
    end

    def waiting(scope)
      newer_from = @from_ids ? Message.sanitize_sql_array([ "AND newer.sender_person_id IN (?)", @from_ids ]) : ""
      scope = scope.where(<<~SQL.squish)
        NOT EXISTS (SELECT 1 FROM messages newer
                    WHERE newer.topic_id = messages.topic_id AND newer.is_patch_submission
                      #{newer_from}
                      AND (newer.created_at, newer.id) > (messages.created_at, messages.id))
        AND NOT EXISTS (SELECT 1 FROM messages reply
                        WHERE reply.topic_id = messages.topic_id AND reply.created_at > messages.created_at
                          AND reply.sender_person_id <> messages.sender_person_id)
        AND NOT EXISTS (SELECT 1 FROM topics landed
                        WHERE landed.id = messages.topic_id AND landed.last_commit_at > messages.created_at)
      SQL
      scope = scope.where("messages.created_at < ?", @waiting_before) if @waiting_before
      scope
    end
  end
end
