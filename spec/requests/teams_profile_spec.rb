require "rails_helper"

RSpec.describe "TeamsProfile", type: :request do
  def sign_in(email:, password: "secret")
    post session_path, params: { email: email, password: password }
    expect(response).to redirect_to(root_path)
  end

  def attach_verified_alias(user, email:, primary: true)
    al = create(:alias, user: user, email: email)
    if primary && user.person&.default_alias_id.nil?
      user.person.update!(default_alias_id: al.id)
    end
    Alias.by_email(email).update_all(verified_at: Time.current)
    al
  end

  describe "GET /team/:name" do
    let!(:team) { create(:team, name: "test-team") }
    let!(:admin) { create(:user, password: "secret", password_confirmation: "secret") }
    let!(:member) { create(:user, password: "secret", password_confirmation: "secret") }
    let!(:non_member) { create(:user, password: "secret", password_confirmation: "secret") }

    before do
      create(:team_member, team: team, user: admin, role: "admin")
      create(:team_member, team: team, user: member, role: "member")
    end

    context "with private team (default)" do
      it "redirects guests to sign in" do
        get team_profile_path("test-team")
        expect(response).to redirect_to(new_session_path)
      end

      it "returns 404 for signed-in non-members" do
        attach_verified_alias(non_member, email: "non-member@example.com")
        sign_in(email: "non-member@example.com")

        get team_profile_path("test-team")
        expect(response).to have_http_status(:not_found)
      end

      it "allows signed-in team members" do
        attach_verified_alias(member, email: "member@example.com")
        sign_in(email: "member@example.com")

        get team_profile_path("test-team")
        expect(response).to have_http_status(:success)
      end
    end

    context "with visible team" do
      before { team.update!(visibility: :visible) }

      it "allows guests to view" do
        get team_profile_path("test-team")
        expect(response).to have_http_status(:success)
      end

      it "allows non-members to view" do
        attach_verified_alias(non_member, email: "non-member@example.com")
        sign_in(email: "non-member@example.com")

        get team_profile_path("test-team")
        expect(response).to have_http_status(:success)
      end
    end

    context "with open team" do
      before { team.update!(visibility: :open) }

      it "allows guests to view" do
        get team_profile_path("test-team")
        expect(response).to have_http_status(:success)
      end

      it "allows non-members to view" do
        attach_verified_alias(non_member, email: "non-member@example.com")
        sign_in(email: "non-member@example.com")

        get team_profile_path("test-team")
        expect(response).to have_http_status(:success)
      end
    end

    it "returns 404 for non-existent teams" do
      get team_profile_path("non-existent")
      expect(response).to have_http_status(:not_found)
    end

    it "shows the sender column and links team activity rows to the sender profile" do
      team.update!(visibility: :visible)

      member_alias = attach_verified_alias(member, email: "member@example.com")
      create(:team_member, team: team, user: non_member, role: "member")
      sender_alias = attach_verified_alias(non_member, email: "sender@example.com")

      topic = create(:topic, creator_alias: member_alias, title: "Sender activity thread")
      create(:message, topic: topic, sender: sender_alias, sender_person_id: non_member.person.id, created_at: 2.days.ago, updated_at: 2.days.ago)

      get team_profile_path("test-team")

      expect(response).to have_http_status(:success)
      expect(response.body).to include("<th>Sender</th>")
      expect(response.body).to include("sender@example.com")
      expect(response.body).to include(person_path("sender@example.com"))
      expect(response.body).to include("Sender activity thread")
    end

    it "renders the all-time stat strip" do
      team.update!(visibility: :visible)
      member_alias = attach_verified_alias(member, email: "strip-member@example.com")
      topic = create(:topic, creator_alias: member_alias)
      create(:message, topic: topic, sender: member_alias, sender_person_id: member.person.id)

      get team_profile_path("test-team")

      expect(response.body).to include("Messages sent")
      expect(response.body).to include("Commit credits")
    end

    it "counts committer-sourced reviews for everyone" do
      team.update!(visibility: :visible)
      member_alias = attach_verified_alias(member, email: "cr-member@example.com")
      create(:message, topic: create(:topic, creator_alias: member_alias), sender: member_alias, sender_person_id: member.person.id)
      CommitPerson.create!(commit: create(:commit, branches: [ "master" ]), role: "reviewer", person_id: member.person.id, source: "committer")

      get team_profile_path("test-team")
      expect(response.body[/credits-hero-value">([^<]+)</, 1]).to eq("1")
      expect(response.body).to include("1 as committer")
    end

    it "counts llm-sourced commit credits only with the patchset_lineage feature" do
      team.update!(visibility: :visible)
      member_alias = attach_verified_alias(member, email: "llm-member@example.com")
      create(:message, topic: create(:topic, creator_alias: member_alias), sender: member_alias, sender_person_id: member.person.id)
      CommitPerson.create!(commit: create(:commit, branches: [ "master" ]), role: "author", person_id: member.person.id)
      CommitPerson.create!(commit: create(:commit, branches: [ "master" ]), role: "author", person_id: member.person.id, source: "llm", confidence: 0.9)

      get team_profile_path("test-team")
      expect(response.body[/credits-hero-value">([^<]+)</, 1]).to eq("1")

      create(:user_feature, user: non_member, feature: "patchset_lineage")
      sign_in_as(non_member)

      get team_profile_path("test-team")
      expect(response.body[/credits-hero-value">([^<]+)</, 1]).to eq("2")
    end

    it "renders the strip tiles without search links" do
      team.update!(visibility: :visible)
      member_alias = attach_verified_alias(member, email: "nolink-member@example.com")
      topic = create(:topic, creator_alias: member_alias)
      create(:message, topic: topic, sender: member_alias, sender_person_id: member.person.id)

      get team_profile_path("test-team")

      expect(response.body).not_to match(/<a[^>]+class="stat-tile"/)
    end

    it "renders the window boxes without any search link, including Started" do
      team.update!(visibility: :visible)
      member_alias = attach_verified_alias(member, email: "window-member@example.com")
      topic = create(:topic, creator_alias: member_alias, created_at: 2.days.ago)
      create(:message, topic: topic, sender: member_alias, sender_person_id: member.person.id, created_at: 2.days.ago, updated_at: 2.days.ago)

      get team_profile_path("test-team")

      region = response.body[/<div class="activity-summary-groups">.*?<table/m]
      expect(region).to be_present
      expect(region.scan('<a ').size).to eq(0)
    end

    it "aggregates messages sent across multiple team members" do
      team.update!(visibility: :visible)
      member_alias = attach_verified_alias(member, email: "agg-member@example.com")
      admin_alias = attach_verified_alias(admin, email: "agg-admin@example.com")

      topic = create(:topic, creator_alias: member_alias)
      create(:message, topic: topic, sender: member_alias, sender_person_id: member.person.id)
      create(:message, topic: topic, sender: admin_alias, sender_person_id: admin.person.id)

      get team_profile_path("test-team")

      expect(response.body).to include('<span class="stat-value">2</span><span class="stat-label">Messages sent</span>')
    end

    it "renders the stat strip before the activity turbo-frame, not inside it" do
      team.update!(visibility: :visible)
      member_alias = attach_verified_alias(member, email: "position-member@example.com")
      topic = create(:topic, creator_alias: member_alias)
      create(:message, topic: topic, sender: member_alias, sender_person_id: member.person.id)

      get team_profile_path("test-team")

      expect(response.body.index("profile-stats")).to be < response.body.index("team-activity")
    end

    it "omits the strip from the team turbo-frame activity response" do
      team.update!(visibility: :visible)
      member_alias = attach_verified_alias(member, email: "frame-member@example.com")
      topic = create(:topic, creator_alias: member_alias)
      create(:message, topic: topic, sender: member_alias, sender_person_id: member.person.id)

      get team_contributions_path("test-team", year: Date.current.year)

      expect(response.body).not_to include("credits-hero-value")
      expect(response.body).to include("team-activity")
    end

    it "renders the landed ratio band and notable threads for a team" do
      team.update!(visibility: :visible)
      member_alias = attach_verified_alias(member, email: "notable-member@example.com")

      topic = create(:topic, creator_alias: member_alias, title: "Team Notable Thread", created_at: Date.new(2020, 1, 1))
      create(:message, topic: topic, sender: member_alias, sender_person_id: member.person.id, is_patch_submission: true,
             created_at: Date.new(2020, 1, 1), updated_at: Date.new(2020, 1, 1))
      commit = create(:commit)
      create(:commit_topic, commit: commit, topic: topic)
      CommitPerson.create!(commit: commit, role: "author", person_id: member.person.id)

      get team_profile_path("test-team")

      expect(response.body).to include("Patch threads that landed")
      expect(response.body).to include("1 / 1")
      expect(response.body).to include("Team Notable Thread")
      expect(response.body).to include("Longest running")
    end
  end
end
