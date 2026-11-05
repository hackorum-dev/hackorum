# Deployment flavor, orthogonal to Rails.env: staging runs RAILS_ENV=production
# with real data and must only differ where the spec says so.
module Hackorum
  ENVS = %w[production staging].freeze

  def self.env
    value = ENV["HACKORUM_ENV"].to_s.strip
    return "production" if value.empty?
    raise ArgumentError, "HACKORUM_ENV must be one of #{ENVS.join(', ')}, got #{value.inspect}" unless ENVS.include?(value)
    value
  end

  def self.staging? = env == "staging"
end
