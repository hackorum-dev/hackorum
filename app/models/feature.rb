class Feature
  ALL = {
    email_sending: "Email sending",
    patchset_lineage: "Patchset lineage"
  }.freeze

  NAMES = ALL.keys.map(&:to_s).freeze

  def self.valid?(name)
    ALL.key?(name.to_sym)
  rescue NoMethodError
    false
  end

  def self.label(name)
    ALL[name.to_sym]
  end

  def self.names
    ALL.keys
  end

  def self.access_by_user(name)
    name = name.to_s
    access = Hash.new { |h, k| h[k] = { direct: false, teams: [] } }
    UserFeature.where(feature: name).pluck(:user_id).each { |uid| access[uid][:direct] = true }
    TeamMember.joins(team: :team_features)
              .where(team_features: { feature: name })
              .order("teams.name")
              .pluck(:user_id, "teams.name")
              .each { |uid, team| access[uid][:teams] << team }
    access.default_proc = nil
    access
  end
end
