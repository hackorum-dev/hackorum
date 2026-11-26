require "json"

module Classify
  class Ingestor
    Error = Class.new(StandardError)

    SCHEMA = JSONSchemer.schema(Rails.root.join("config/classify/result.schema.json"))

    def initialize(run)
      @run = run
    end

    def call(result_path)
      data = parse(result_path)
      validate!(data)
      topic = @run.topic

      ActiveRecord::Base.transaction do
        human = FeatureGroupTopic.where(topic_id: topic.id, source: "human").exists?
        group = resolve_group(data["group"], create: !human)
        Classify::BotNote.new(topic).write!(tags_for(data))
        old_id, new_id = apply_membership(topic, group)
        join_linked(topic, group, data["join_linked"]) if group && !human
        @run.finish!(status: "done", result: data, kind: data["kind"], size: data["size"], enhancement: Classify::SIZED_KINDS.include?(data["kind"]) ? data["enhancement"] : nil,
                     not_a_bug: data["not_a_bug"], feature_group_id: group&.id)
        FeatureGroups::Versions.refresh_isolated!([ old_id, new_id ].compact)
      end
      @run
    end

    private

    def parse(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      raise Error, "invalid JSON: #{e.message}"
    end

    def validate!(data)
      errors = SCHEMA.validate(data).map { |e| e["error"] }
      raise Error, "schema: #{errors.first(3).join('; ')}" if errors.any?

      sized = Classify::SIZED_KINDS.include?(data["kind"])
      raise Error, "size required for #{data['kind']}" if sized && data["size"].nil?
      raise Error, "size not allowed for #{data['kind']}" if !sized && data["size"]

      raise Error, "enhancement required for #{data['kind']}" if sized && data["enhancement"].nil?
      raise Error, "enhancement not allowed for #{data['kind']}" if !sized && data["enhancement"]

      group = data["group"]
      raise Error, "group id and new_name together" if group["id"] && group["new_name"].present?
    end

    def tags_for(data)
      tags = [ data["kind"], data["size"] ]
      tags << Classify::ENHANCEMENT_TAG if data["enhancement"]
      tags << "not-a-bug" if data["not_a_bug"] && data["kind"] == "bug"
      tags.compact
    end

    # create: false (human membership) ignores new names, so no orphan groups
    def resolve_group(spec, create:)
      if spec["id"]
        found = FeatureGroup.find_by(id: spec["id"]) or raise Error, "unknown group id #{spec['id']}"
        found.surviving
      elsif spec["new_name"].present? && create
        FeatureGroup.find_by_normalized_name(spec["new_name"]) ||
          FeatureGroup.create!(name: spec["new_name"].strip, summary: spec["new_summary"], source: "llm",
                               created_by_run_id: @run.id)
      end
    end

    def join_linked(topic, group, ids)
      linked = TopicLink.where(topic_id: topic.id, other_topic_id: ids).distinct.pluck(:other_topic_id)
      linked = Scope.topics.where(id: linked).pluck(:id)
      taken = FeatureGroupTopic.where(topic_id: linked).pluck(:topic_id)
      now = Time.current
      rows = (linked - taken - [ topic.id ]).map do |id|
        { topic_id: id, feature_group_id: group.id, source: "llm", classification_run_id: @run.id,
          created_at: now, updated_at: now }
      end
      FeatureGroupTopic.insert_all(rows, unique_by: :topic_id) if rows.any?
    end

    # returns [old group id, new group id]
    def apply_membership(topic, group)
      row = FeatureGroupTopic.find_by(topic_id: topic.id)
      return [ row.feature_group_id, row.feature_group_id ] if row&.human?

      old_id = row&.feature_group_id
      if group
        row ||= FeatureGroupTopic.new(topic_id: topic.id)
        row.update!(feature_group_id: group.id, source: "llm", classification_run_id: @run.id)
      else
        row&.destroy!
      end
      [ old_id, group&.id ]
    end
  end
end
