module Lineage
  module ThreadRank
    module_function

    def key_sql(topic_id)
      "COALESCE((SELECT max(rank_m.created_at) FROM messages rank_m WHERE rank_m.topic_id = #{topic_id} AND rank_m.is_patch_submission), '-infinity'::timestamp)"
    end

    def before_sql(u, t)
      "(#{key_sql(u)} > #{key_sql(t)} OR (#{key_sql(u)} = #{key_sql(t)} AND #{u} < #{t}))"
    end

    def order(topic_ids)
      Topic.where(id: topic_ids).order(Arel.sql("#{key_sql('topics.id')} DESC, topics.id ASC")).pluck(:id)
    end
  end
end
