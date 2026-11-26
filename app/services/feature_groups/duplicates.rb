module FeatureGroups
  class Duplicates
    MIN_SIMILARITY = 0.45
    MIN_LINKS = 2

    def self.pairs(limit: 100)
      new.pairs(limit: limit)
    end

    def pairs(limit: 100)
      rows = ActiveRecord::Base.connection.select_all(sql(limit)).to_a
      groups = FeatureGroup.where(id: rows.flat_map { |r| [ r["a_id"], r["b_id"] ] }).index_by(&:id)
      rows.map do |r|
        { a: groups[r["a_id"]], b: groups[r["b_id"]], similarity: r["sim"].to_f, links: r["links"].to_i }
      end
    end

    private

    def sql(limit)
      <<~SQL.squish
        WITH member_pairs AS (
          SELECT DISTINCT LEAST(x.topic_id, y.topic_id) AS t1, GREATEST(x.topic_id, y.topic_id) AS t2,
                 LEAST(x.feature_group_id, y.feature_group_id) AS low_id,
                 GREATEST(x.feature_group_id, y.feature_group_id) AS high_id
          FROM topic_links tl
          JOIN feature_group_topics x ON x.topic_id = tl.topic_id
          JOIN feature_group_topics y ON y.topic_id = tl.other_topic_id
          WHERE x.feature_group_id <> y.feature_group_id
        ),
        link_counts AS (
          SELECT low_id, high_id, COUNT(*) AS links FROM member_pairs GROUP BY low_id, high_id
        ),
        sims AS (
          SELECT a.id AS low_id, b.id AS high_id
          FROM feature_groups a
          JOIN feature_groups b ON a.id < b.id AND a.name % b.name
          WHERE a.merged_into_id IS NULL AND b.merged_into_id IS NULL
        ),
        candidates AS (
          SELECT COALESCE(s.low_id, l.low_id) AS low_id, COALESCE(s.high_id, l.high_id) AS high_id,
                 COALESCE(l.links, 0) AS links
          FROM sims s FULL JOIN link_counts l ON l.low_id = s.low_id AND l.high_id = s.high_id
        )
        SELECT c.low_id AS a_id, c.high_id AS b_id,
               similarity(a.name, b.name) AS sim, c.links
        FROM candidates c
        JOIN feature_groups a ON a.id = c.low_id AND a.merged_into_id IS NULL
        JOIN feature_groups b ON b.id = c.high_id AND b.merged_into_id IS NULL
        WHERE (similarity(a.name, b.name) >= #{MIN_SIMILARITY} OR c.links >= #{MIN_LINKS})
          AND NOT EXISTS (SELECT 1 FROM feature_group_dismissed_pairs d WHERE d.low_id = c.low_id AND d.high_id = c.high_id)
        ORDER BY c.links DESC, sim DESC, c.low_id, c.high_id
        LIMIT #{Integer(limit)}
      SQL
    end
  end
end
