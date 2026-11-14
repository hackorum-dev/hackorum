class TopicLink < ApplicationRecord
  KINDS = %w[commit mention commitfest].freeze
  DIRECTIONS = %w[both out in].freeze
  MIRROR = { "both" => "both", "out" => "in", "in" => "out" }.freeze

  belongs_to :topic
  belongs_to :other_topic, class_name: "Topic"
  belongs_to :ref, polymorphic: true

  validates :kind, inclusion: { in: KINDS }
  validates :direction, inclusion: { in: DIRECTIONS }
end
