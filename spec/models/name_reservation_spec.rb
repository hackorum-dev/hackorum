# frozen_string_literal: true

require "rails_helper"

RSpec.describe NameReservation, type: :model do
  let(:user) { create(:user) }
  let(:team) { Team.create!(name: "team1") }

  it "reserves and prevents duplicates across owners" do
    NameReservation.reserve!(name: "test", owner: user)
    expect {
      NameReservation.reserve!(name: "test", owner: team)
    }.to raise_error(ActiveRecord::RecordInvalid)
  end

  describe "reserved names" do
    it "refuses to reserve global" do
      user = create(:user)
      expect {
        described_class.reserve!(name: "Global", owner: user)
      }.to raise_error(ActiveRecord::RecordInvalid)
    end

    it "flags global as reserved" do
      expect(described_class.reserved?(" GLOBAL ")).to be(true)
      expect(described_class.reserved?("alice")).to be(false)
    end

    it "makes global an invalid username and team name" do
      user = build(:user, username: "global")
      team = build(:team, name: "global")

      expect(user).not_to be_valid
      expect(user.errors[:username]).to include("is reserved")
      expect(team).not_to be_valid
      expect(team.errors[:name]).to include("is reserved")
    end
  end
end
