require "rails_helper"

RSpec.describe SavedSearch, type: :model do
  describe "validations" do
    it "requires name" do
      ss = SavedSearch.new(query: "test", scope: "global")
      expect(ss).not_to be_valid
      expect(ss.errors[:name]).to be_present
    end

    it "requires query" do
      ss = SavedSearch.new(name: "test", scope: "global")
      expect(ss).not_to be_valid
      expect(ss.errors[:query]).to be_present
    end

    it "rejects duplicate names within same scope and owner" do
      create(:saved_search, name: "My Search", scope: "global")
      dup = build(:saved_search, name: "My Search", scope: "global")
      expect(dup).not_to be_valid
    end

    it "allows same name in different scopes" do
      create(:saved_search, name: "My Search", scope: "global")
      user_search = build(:saved_search, name: "My Search", scope: "user", user: create(:user))
      expect(user_search).to be_valid
    end

    it "rejects having both user and team" do
      ss = build(:saved_search, user: create(:user), team: create(:team), scope: "user")
      expect(ss).not_to be_valid
      expect(ss.errors[:base]).to include("cannot have both user and team")
    end
  end

  describe "#system_defined?" do
    it "returns true for user-scope without user" do
      ss = build(:saved_search, scope: "user", user: nil)
      expect(ss.system_defined?).to be true
    end

    it "returns true for team-scope without team" do
      ss = build(:saved_search, scope: "team", team: nil)
      expect(ss.system_defined?).to be true
    end

    it "returns false for user-scope with user" do
      ss = build(:saved_search, scope: "user", user: create(:user))
      expect(ss.system_defined?).to be false
    end

    it "returns false for global scope" do
      ss = build(:saved_search, scope: "global")
      expect(ss.system_defined?).to be false
    end
  end

  describe "#resolve_query" do
    it "returns query as-is without team" do
      ss = build(:saved_search, query: "from:{{team_name}}")
      expect(ss.resolve_query).to eq("from:{{team_name}}")
    end

    it "replaces {{team_name}} with team name" do
      team = build(:team, name: "core-team")
      ss = build(:saved_search, query: "from:{{team_name}}")
      expect(ss.resolve_query(team: team)).to eq("from:core-team")
    end
  end

  describe ".visible_to" do
    let(:user) { create(:user) }
    let(:team) { create(:team) }

    before do
      create(:team_member, team: team, user: user)
    end

    it "includes global searches for any user" do
      global = create(:saved_search, scope: "global")
      expect(SavedSearch.visible_to(user)).to include(global)
    end

    it "includes user's own searches" do
      own = create(:saved_search, scope: "user", user: user)
      expect(SavedSearch.visible_to(user)).to include(own)
    end

    it "excludes other users' searches" do
      other = create(:saved_search, scope: "user", user: create(:user))
      expect(SavedSearch.visible_to(user)).not_to include(other)
    end

    it "includes user templates" do
      template = create(:saved_search, scope: "user", user: nil)
      expect(SavedSearch.visible_to(user)).to include(template)
    end

    it "includes team searches for member's teams" do
      team_search = create(:saved_search, scope: "team", team: team)
      expect(SavedSearch.visible_to(user)).to include(team_search)
    end

    it "excludes team searches for non-member teams" do
      other_team = create(:team)
      team_search = create(:saved_search, scope: "team", team: other_team)
      expect(SavedSearch.visible_to(user)).not_to include(team_search)
    end

    it "includes team templates" do
      template = create(:saved_search, scope: "team", team: nil)
      expect(SavedSearch.visible_to(user)).to include(template)
    end
  end

  describe ".visible_to_unhidden" do
    let(:user) { create(:user) }

    it "excludes hidden searches" do
      search = create(:saved_search, scope: "global")
      create(:saved_search_preference, saved_search: search, user: user, hidden: true)
      expect(SavedSearch.visible_to_unhidden(user)).not_to include(search)
    end

    it "includes non-hidden searches" do
      search = create(:saved_search, scope: "global")
      expect(SavedSearch.visible_to_unhidden(user)).to include(search)
    end
  end
end
