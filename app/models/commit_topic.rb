class CommitTopic < ApplicationRecord
  SOURCES = %w[trailer llm].freeze

  belongs_to :commit
  belongs_to :topic

  validates :source, inclusion: { in: SOURCES }

  scope :trailer, -> { where(source: "trailer") }
  scope :llm, -> { where(source: "llm") }
end
