module Classify
  LISTS = %w[pgsql-hackers pgsql-bugs pgsql-docs].freeze
  BOT_USERNAME = "hackorum-bot"
  KIND_TAGS = %w[feature performance bug refactor docs tests-build discussion].freeze
  SIZE_TAGS = %w[major moderate minor].freeze
  OUTCOME_TAGS = %w[not-a-bug].freeze
  SIZED_KINDS = %w[feature performance].freeze
  ENHANCEMENT_TAG = "enhancement".freeze
  TAGS = (KIND_TAGS + SIZE_TAGS + OUTCOME_TAGS + [ ENHANCEMENT_TAG ]).freeze
  MODEL = "gpt-6.2-sol".freeze
  EFFORT = "medium".freeze

  RUNNER_PROMPT = "Classify the mailing list thread given on stdin as its instructions say. " \
                  "Your final message must be only the JSON object the output schema describes."

  def self.runner(model: MODEL, effort: EFFORT, timeout: 600, **overrides)
    Lineage::CodexRunner.new(
      model: model, effort: effort, timeout: timeout,
      config_source: Rails.root.join("config/classify/codex.config.toml"),
      schema_path: Rails.root.join("config/classify/result.schema.json"),
      sandbox: "read-only", stdin_file: "prompt.md", prompt: RUNNER_PROMPT,
      codex_home: Rails.root.join("tmp/codex_home_classify").to_s,
      **overrides
    )
  end

  def self.bot_user
    User.find_by!(username: BOT_USERNAME)
  end

  # nil until setup ran
  def self.bot_user_id
    User.where(username: BOT_USERNAME).pick(:id)
  end

  def self.kind(tags)
    (tags & KIND_TAGS).first
  end

  def self.enhancement?(tags)
    tags.include?(ENHANCEMENT_TAG)
  end

  def self.size(tags)
    (tags & SIZE_TAGS).first
  end
end
