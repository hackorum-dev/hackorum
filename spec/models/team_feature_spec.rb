require "rails_helper"

RSpec.describe TeamFeature do
  let(:team) { create(:team) }

  it "is valid with a known feature name" do
    expect(build(:team_feature, team: team, feature: "email_sending")).to be_valid
  end

  it "is invalid with an unknown feature name" do
    tf = build(:team_feature, team: team, feature: "bogus")
    expect(tf).not_to be_valid
    expect(tf.errors[:feature]).to be_present
  end

  it "is invalid without a feature" do
    expect(build(:team_feature, team: team, feature: nil)).not_to be_valid
  end

  it "enforces uniqueness per (team, feature)" do
    create(:team_feature, team: team, feature: "email_sending")
    expect(build(:team_feature, team: team, feature: "email_sending")).not_to be_valid
  end

  it "is destroyed with its team" do
    create(:team_feature, team: team)
    expect { team.destroy }.to change(TeamFeature, :count).by(-1)
  end
end
