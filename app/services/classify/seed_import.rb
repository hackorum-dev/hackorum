module Classify
  module SeedImport
    def self.call(entries)
      out = { groups: 0, memberships: 0, skipped: 0 }
      entries.each do |entry|
        group = FeatureGroup.find_by_normalized_name(entry["name"])
        topic_ids = Array(entry["topic_ids"])
        valid = Topic.where(id: topic_ids).pluck(:id)
        out[:skipped] += topic_ids.size - valid.size
        valid.each do |topic_id|
          link = FeatureGroupTopic.find_or_initialize_by(topic_id: topic_id)
          if link.human?
            out[:skipped] += 1
            next
          end
          unless group
            group = FeatureGroup.create!(name: entry["name"].to_s.strip, summary: entry["summary"], source: "seed")
            out[:groups] += 1
          end
          link.update!(feature_group: group, source: "seed")
          out[:memberships] += 1
        end
      end
      out
    end
  end
end
