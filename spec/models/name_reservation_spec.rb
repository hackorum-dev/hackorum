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

    it "blocks system mail names everywhere" do
      %w[receiver app noreply postmaster dmarc mailer-daemon].each do |name|
        expect(described_class.reserved?(name)).to be(true)
        expect(build(:user, username: name)).not_to be_valid
        expect(build(:team, name: name)).not_to be_valid
      end
    end

    it "blocks role names for users and teams but lets reserve! take them" do
      expect(described_class.role_name?(" Info ")).to be(true)
      expect(described_class.reserved?("info")).to be(false)
      user = build(:user, username: "info")
      expect(user).not_to be_valid
      expect(user.errors[:username]).to include("is reserved")
      expect(build(:team, name: "Security").tap(&:valid?).errors[:name]).to include("is reserved")
      expect { described_class.reserve!(name: "info", owner: create(:user)) }.not_to raise_error
    end

    it "leaves an existing holder of a role name alone" do
      user = create(:user)
      user.update_columns(username: "admin")
      user.reload
      expect(user.update(aware_before: Time.current)).to be(true)
    end

    it "leaves an existing holder of a system name alone" do
      user = create(:user)
      user.update_columns(username: "postmaster")
      user.reload
      expect(user.update(aware_before: Time.current)).to be(true)
    end
  end
end
