# frozen_string_literal: true

require "rails_helper"

RSpec.describe User, type: :model do
  describe "username validations" do
    it "rejects username already taken by another user" do
      user1 = create(:user, username: "taken")
      user2 = create(:user)

      user2.username = "taken"
      expect(user2).not_to be_valid
      expect(user2.errors[:username]).to include("has already been taken")
    end

    it "rejects username case-insensitively against other users" do
      create(:user, username: "TakenName")
      user2 = create(:user)

      user2.username = "takenname"
      expect(user2).not_to be_valid
      expect(user2.errors[:username]).to include("has already been taken")
    end

    it "rejects username already reserved by a team" do
      Team.create!(name: "teamname")
      user = create(:user)

      user.username = "teamname"
      expect(user).not_to be_valid
      expect(user.errors[:username]).to include("is already taken")
    end

    it "rejects username case-insensitively against teams" do
      Team.create!(name: "MyTeam")
      user = create(:user)

      user.username = "myteam"
      expect(user).not_to be_valid
      expect(user.errors[:username]).to include("is already taken")
    end

    it "allows setting a new unique username" do
      user = create(:user)
      expect(user.update(username: "unique_name")).to be(true)
      expect(NameReservation.find_by(name: "unique_name")).to be_present
    end

    it "allows updating other attributes without affecting username reservation" do
      user = create(:user, username: "myname")
      expect(user.update(mention_restriction: :teammates_only)).to be(true)

      reservation = NameReservation.find_by(name: "myname")
      expect(reservation).to be_present
      expect(reservation.owner_type).to eq("User")
      expect(reservation.owner_id).to eq(user.id)
    end

    it "creates a name reservation when username is set" do
      user = create(:user)
      user.update!(username: "reserved_name")

      reservation = NameReservation.find_by(name: "reserved_name")
      expect(reservation).to be_present
      expect(reservation.owner_type).to eq("User")
      expect(reservation.owner_id).to eq(user.id)
    end

    it "releases old reservation and creates new one when username changes" do
      user = create(:user, username: "oldname")
      expect(NameReservation.find_by(name: "oldname")).to be_present

      user.update!(username: "newname")
      expect(NameReservation.find_by(name: "oldname")).to be_nil
      expect(NameReservation.find_by(name: "newname")).to be_present
    end

    it "rolls back username change if reservation fails" do
      user = create(:user, username: "original")
      Team.create!(name: "blocked")

      expect(user.update(username: "blocked")).to be(false)
      user.reload
      expect(user.username).to eq("original")
      expect(NameReservation.find_by(name: "original")).to be_present
    end
  end

  describe "#can_send_email?" do
    let(:user) { create(:user) }

    it "is false with no identities" do
      expect(user.can_send_email?).to be false
    end

    it "is false when no identity is send-authorized" do
      create(:identity, user: user, refresh_token: nil)
      expect(user.can_send_email?).to be false
    end

    it "is true when at least one identity is send-authorized" do
      create(:identity, user: user, refresh_token: "r", send_authorized_at: 1.hour.ago)
      expect(user.can_send_email?).to be true
    end

    it "is false when all identities are revoked" do
      create(:identity, user: user, refresh_token: "r", send_revoked_at: Time.current)
      expect(user.can_send_email?).to be false
    end
  end

  describe "#sender_alias_for" do
    let(:user) { create(:user) }

    it "prefers a named alias over a Noname alias for the same email" do
      noname = create(:alias, user: user, email: "a@b", name: "Noname", sender_count: 10)
      named  = create(:alias, user: user, email: "a@b", name: "Alice", sender_count: 1)
      user.person.recalculate_default_alias!
      user.person.reload

      expect(user.sender_alias_for("a@b")).to eq(named)
      expect(user.sender_alias_for("a@b")).not_to eq(noname)
    end

    it "uses the user's primary alias when its email matches, even over a higher sender_count alias" do
      _other = create(:alias, user: user, email: "a@b", name: "Aliased", sender_count: 999)
      primary = create(:alias, user: user, email: "a@b", name: "Alice")
      user.person.update!(default_alias: primary)

      expect(user.sender_alias_for("a@b")).to eq(primary)
    end

    it "ignores the primary alias when its email does not match" do
      primary = create(:alias, user: user, email: "primary@x", name: "Alice")
      user.person.update!(default_alias: primary)
      other = create(:alias, user: user, email: "other@x", name: "Other")

      expect(user.sender_alias_for("other@x")).to eq(other)
    end

    it "ignores the primary alias when it does not belong to this user" do
      foreign_user = create(:user)
      foreign_primary = create(:alias, user: foreign_user, email: "a@b", name: "Foreign", person: user.person)
      user.person.update!(default_alias: foreign_primary)
      mine = create(:alias, user: user, email: "a@b", name: "Mine")

      expect(user.sender_alias_for("a@b")).to eq(mine)
    end

    it "prefers higher sender_count when no primary alias matches the email" do
      elsewhere = create(:alias, user: user, email: "primary@x", name: "Primary")
      user.person.update!(default_alias: elsewhere)
      _low  = create(:alias, user: user, email: "a@b", name: "Alice",  sender_count: 1)
      high  = create(:alias, user: user, email: "a@b", name: "Alicia", sender_count: 99)
      user.person.reload

      expect(user.sender_alias_for("a@b")).to eq(high)
    end

    it "matches case- and whitespace-insensitively on email" do
      named = create(:alias, user: user, email: "alice@example.com", name: "Alice")

      expect(user.sender_alias_for("  Alice@Example.COM  ")).to eq(named)
    end

    it "returns the Noname alias when no other alias exists for the email" do
      noname = create(:alias, user: user, email: "a@b", name: "Noname")

      expect(user.sender_alias_for("a@b")).to eq(noname)
    end

    it "returns nil when no alias matches the email" do
      create(:alias, user: user, email: "a@b", name: "Alice")

      expect(user.sender_alias_for("missing@x")).to be_nil
    end

    it "ignores aliases belonging to other users" do
      other = create(:user)
      create(:alias, user: other, email: "a@b", name: "OtherAlice")

      expect(user.sender_alias_for("a@b")).to be_nil
    end
  end

  describe "#has_feature?" do
    it "returns true for admin regardless of enrollment" do
      admin = create(:user, admin: true)
      expect(admin.has_feature?(:email_sending)).to be true
    end

    it "returns true for non-admin enrolled in the feature" do
      user = create(:user)
      create(:user_feature, user: user, feature: "email_sending")
      expect(user.has_feature?(:email_sending)).to be true
    end

    it "returns false for non-admin without enrollment" do
      user = create(:user)
      expect(user.has_feature?(:email_sending)).to be false
    end

    it "accepts strings as well as symbols" do
      user = create(:user)
      create(:user_feature, user: user, feature: "email_sending")
      expect(user.has_feature?("email_sending")).to be true
    end

    context "via team" do
      let(:user) { create(:user) }
      let(:team) { create(:team) }

      before { create(:team_member, team: team, user: user) }

      it "returns true when the user's team has the feature" do
        create(:team_feature, team: team, feature: "email_sending")
        expect(user.has_feature?(:email_sending)).to be true
      end

      it "returns false for a different feature on the team" do
        create(:team_feature, team: team, feature: "patchset_lineage")
        expect(user.has_feature?(:email_sending)).to be false
      end

      it "returns false when only another team has the feature" do
        create(:team_feature, team: create(:team), feature: "email_sending")
        expect(user.has_feature?(:email_sending)).to be false
      end

      it "returns false after leaving the team" do
        create(:team_feature, team: team, feature: "email_sending")
        TeamMember.where(team: team, user: user).destroy_all
        expect(user.has_feature?(:email_sending)).to be false
      end

      it "returns false after the team is unenrolled" do
        create(:team_feature, team: team, feature: "email_sending")
        team.team_features.destroy_all
        expect(user.has_feature?(:email_sending)).to be false
      end

      it "returns false after the team is destroyed" do
        create(:team_feature, team: team, feature: "email_sending")
        team.destroy
        expect(user.has_feature?(:email_sending)).to be false
      end
    end
  end
end
