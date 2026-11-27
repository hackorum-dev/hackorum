require "rails_helper"

RSpec.describe "Search has:patch progress conditions", type: :service do
  let(:parser) { Search::QueryParser.new }
  let(:me) { create(:person) }
  let(:user) { create(:user, person: me) }
  let(:alice) { create(:person) }
  let(:bob) { create(:person) }
  let!(:me_alias) { create(:alias, name: "Me Myself", email: "me@example.com", person: me) }
  let!(:alice_alias) { create(:alias, name: "Alice Wonder", email: "alice@example.com", person: alice) }
  let!(:bob_alias) { create(:alias, name: "Bob Builder", email: "bob@example.com", person: bob) }

  def post(topic, who, days, patch: false)
    sender = { me: me_alias, alice: alice_alias, bob: bob_alias }.fetch(who)
    person = { me: me, alice: alice, bob: bob }.fetch(who)
    msg = create(:message, topic: topic, sender: sender, sender_person_id: person.id,
                           is_patch_submission: patch, created_at: days.days.ago)
    topic.update_denormalized_counts!
    msg
  end

  def build(query, current_user: user)
    ast = parser.parse(query)
    validated = Search::QueryValidator.new(ast).validate
    Search::QueryBuilder.new(ast: validated.ast, user: current_user).build
  end

  def ids(query, **opts)
    build(query, **opts).relation.pluck(:id)
  end

  let!(:new_since_me) { create(:topic).tap { |t| post(t, :me, 5); post(t, :alice, 3, patch: true) } }
  let!(:old_patch) { create(:topic).tap { |t| post(t, :alice, 5, patch: true); post(t, :me, 3) } }
  let!(:never_posted) { create(:topic).tap { |t| post(t, :alice, 3, patch: true) } }
  let!(:my_own) { create(:topic).tap { |t| post(t, :me, 3, patch: true) } }
  let!(:waiting_self_followup) do
    create(:topic).tap { |t| post(t, :alice, 10, patch: true); post(t, :alice, 9) }
  end
  let!(:answered) { create(:topic).tap { |t| post(t, :alice, 10, patch: true); post(t, :bob, 9) } }
  let!(:older_reply) { create(:topic).tap { |t| post(t, :bob, 12); post(t, :alice, 10, patch: true) } }
  let!(:newer_patch_other) do
    create(:topic).tap { |t| post(t, :me, 10, patch: true); post(t, :bob, 9, patch: true) }
  end
  let!(:no_patch) { create(:topic).tap { |t| post(t, :alice, 4) } }

  describe "after:" do
    it "finds patches newer than my last message" do
      result = ids("has:patch[after:me]")
      expect(result).to include(new_since_me.id)
      expect(result).not_to include(old_patch.id, never_posted.id, my_own.id)
    end

    it "combines with from: on the same patch" do
      late_bob = create(:topic).tap { |t| post(t, :me, 5); post(t, :bob, 3, patch: true) }
      result = ids("has:patch[from:alice, after:me]")
      expect(result).to include(new_since_me.id)
      expect(result).not_to include(late_bob.id)
    end

    it "works with a team" do
      team = create(:team, name: "crew", visibility: :visible)
      create(:team_member, team: team, user: user)
      create(:team_member, team: team, user: create(:user, person: bob))
      topic = create(:topic).tap { |t| post(t, :me, 5); post(t, :bob, 3, patch: true) }
      expect(ids("has:patch[after:crew]")).to include(topic.id)
    end
  end

  describe "waiting:" do
    it "finds unanswered patches" do
      result = ids("has:patch[waiting:any]")
      expect(result).to include(waiting_self_followup.id, older_reply.id, newer_patch_other.id)
      expect(result).not_to include(answered.id, no_patch.id)
    end

    it "honors the age cutoff" do
      expect(ids("has:patch[waiting:1w]")).to include(waiting_self_followup.id)
      expect(ids("has:patch[waiting:2w]")).not_to include(waiting_self_followup.id)
    end

    it "only considers the newest patch of the given sender" do
      expect(ids("has:patch[from:me, waiting:any]")).not_to include(newer_patch_other.id)
    end

    it "is cleared by a later commit" do
      create(:commit_topic, topic: waiting_self_followup, commit: create(:commit, committed_at: 8.days.ago))
      expect(ids("has:patch[waiting:any]")).not_to include(waiting_self_followup.id)
    end

    it "is not cleared by an earlier commit" do
      create(:commit_topic, topic: waiting_self_followup, commit: create(:commit, committed_at: 12.days.ago))
      expect(ids("has:patch[waiting:any]")).to include(waiting_self_followup.id)
    end

    it "negates" do
      result = ids("-has:patch[waiting:any]")
      expect(result).to include(answered.id, no_patch.id)
      expect(result).not_to include(waiting_self_followup.id)
    end

    it "ands with attachment count" do
      two = create(:topic)
      one = create(:topic)
      m2 = post(two, :alice, 10, patch: true)
      m1 = post(one, :alice, 10, patch: true)
      create_list(:attachment, 2, message: m2)
      create(:attachment, message: m1)
      result = ids("has:patch[waiting:any, count:>=2]")
      expect(result).to include(two.id)
      expect(result).not_to include(one.id)
    end
  end

  describe "signed out" do
    it "matches nothing with a warning, negation matches all" do
      query = build("has:patch[after:me]", current_user: nil)
      expect(query.relation).to be_empty
      expect(query.warnings).not_to be_empty
      expect(ids("-has:patch[after:me]", current_user: nil)).to match_array(Topic.pluck(:id))
    end
  end
end
