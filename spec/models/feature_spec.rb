require "rails_helper"

RSpec.describe Feature do
  describe ".valid?" do
    it "returns true for known feature names (symbol or string)" do
      expect(Feature.valid?(:email_sending)).to be true
      expect(Feature.valid?("email_sending")).to be true
    end

    it "returns false for unknown names" do
      expect(Feature.valid?(:bogus)).to be false
    end
  end

  describe ".label" do
    it "returns the display label" do
      expect(Feature.label(:email_sending)).to eq("Email sending")
    end
  end

  describe ".access_by_user" do
    it "merges direct and team access per user" do
      direct = create(:user)
      both = create(:user)
      via_team = create(:user)
      outsider = create(:user)
      t1 = create(:team, name: "alpha")
      t2 = create(:team, name: "beta")
      other = create(:team)
      create(:user_feature, user: direct, feature: "email_sending")
      create(:user_feature, user: both, feature: "email_sending")
      create(:team_member, team: t1, user: both)
      create(:team_member, team: t1, user: via_team)
      create(:team_member, team: t2, user: via_team)
      create(:team_member, team: other, user: outsider)
      create(:team_feature, team: t1, feature: "email_sending")
      create(:team_feature, team: t2, feature: "email_sending")

      result = Feature.access_by_user("email_sending")

      expect(result).to eq(
        direct.id => { direct: true, teams: [] },
        both.id => { direct: true, teams: [ "alpha" ] },
        via_team.id => { direct: false, teams: [ "alpha", "beta" ] }
      )
    end
  end
end
