# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PersonMergeService do
  let(:admin) { create(:user, admin: true, username: "merge_admin") }
  let(:source) { create(:person) }
  let(:target) { create(:person) }

  def merge(source_person: source, target_person: target, merged_by: admin)
    described_class.new(
      source_person: source_person,
      target_person: target_person,
      merged_by: merged_by
    ).call
  end

  describe "record movement" do
    it "moves the source aliases onto the target and destroys the source" do
      moved = create(:alias, person: source, name: "Old Name", email: "old@example.com")
      create(:alias, person: target, name: "Kept Name", email: "kept@example.com")

      result = merge

      expect(result.success?).to be true
      expect(moved.reload.person_id).to eq(target.id)
      expect(Person.find_by(id: source.id)).to be_nil
    end

    it "reassigns topics, messages and mentions" do
      source_alias = create(:alias, person: source, name: "Old Name", email: "old@example.com")
      create(:alias, person: target, name: "Kept Name", email: "kept@example.com")

      topic = create(:topic, creator_alias: source_alias)
      message = create(:message, topic: topic, sender_alias: source_alias)
      mention = create(:mention, message: message, alias: source_alias)

      merge

      expect(topic.reload.creator_person_id).to eq(target.id)
      expect(message.reload.sender_person_id).to eq(target.id)
      expect(mention.reload.person_id).to eq(target.id)
    end

    it "moves commit_people rows so a committer can be merged" do
      create(:alias, person: source, name: "Old Name", email: "old@example.com")
      create(:alias, person: target, name: "Kept Name", email: "kept@example.com")
      commit_person = create(:commit_person, person: source)

      result = merge

      expect(result.success?).to be true
      expect(commit_person.reload.person_id).to eq(target.id)
    end

    it "merges contributor memberships without duplicating them" do
      create(:alias, person: source, name: "Old Name", email: "old@example.com")
      create(:alias, person: target, name: "Kept Name", email: "kept@example.com")
      ContributorMembership.create!(person: source, contributor_type: "committer")
      ContributorMembership.create!(person: target, contributor_type: "committer")
      ContributorMembership.create!(person: source, contributor_type: "core_team")

      merge

      types = target.reload.contributor_memberships.map(&:contributor_type)
      expect(types).to match_array(%w[committer core_team])
    end

    it "recalculates the target default alias across the combined set" do
      create(:alias, person: target, name: "Noname", email: "noname@example.com", sender_count: 0)
      real = create(:alias, person: source, name: "Real Person", email: "real@example.com", sender_count: 12)

      merge

      expect(target.reload.default_alias_id).to eq(real.id)
    end
  end

  describe "topic participants" do
    def participation_for(topic, person, message_count:, first_at:, last_at:)
      row = TopicParticipant.find_or_create_by!(topic_id: topic.id, person_id: person.id)
      row.update!(message_count: message_count, first_message_at: first_at, last_message_at: last_at)
      row
    end

    it "sums both rows when the two people share a topic" do
      source_alias = create(:alias, person: source, name: "Old Name", email: "old@example.com")
      target_alias = create(:alias, person: target, name: "Kept Name", email: "kept@example.com")
      topic = create(:topic, creator_alias: target_alias)
      create(:message, topic: topic, sender_alias: target_alias)
      create(:message, topic: topic, sender_alias: source_alias)

      participation_for(topic, target, message_count: 5, first_at: 3.days.ago, last_at: 1.day.ago)
      participation_for(topic, source, message_count: 7, first_at: 10.days.ago, last_at: 2.days.ago)

      merge

      rows = TopicParticipant.where(topic_id: topic.id)
      expect(rows.count).to eq(1)
      expect(rows.first.person_id).to eq(target.id)
      expect(rows.first.message_count).to eq(12)
      expect(rows.first.first_message_at).to be_within(1.second).of(10.days.ago)
      expect(rows.first.last_message_at).to be_within(1.second).of(1.day.ago)
    end

    it "refreshes the denormalized topic counts after collapsing a row" do
      source_alias = create(:alias, person: source, name: "Old Name", email: "old@example.com")
      target_alias = create(:alias, person: target, name: "Kept Name", email: "kept@example.com")
      topic = create(:topic, creator_alias: target_alias)
      create(:message, topic: topic, sender_alias: target_alias)
      create(:message, topic: topic, sender_alias: source_alias)

      participation_for(topic, target, message_count: 1, first_at: 3.days.ago, last_at: 1.day.ago)
      participation_for(topic, source, message_count: 1, first_at: 10.days.ago, last_at: 2.days.ago)
      topic.update_columns(participant_count: 2)

      merge

      expect(topic.reload.participant_count).to eq(1)
    end

    it "flags the surviving row as a contributor when the source carried the membership" do
      source_alias = create(:alias, person: source, name: "Old Name", email: "old@example.com")
      target_alias = create(:alias, person: target, name: "Kept Name", email: "kept@example.com")
      ContributorMembership.create!(person: source, contributor_type: "committer")
      topic = create(:topic, creator_alias: target_alias)
      create(:message, topic: topic, sender_alias: target_alias)
      create(:message, topic: topic, sender_alias: source_alias)

      participation_for(topic, target, message_count: 1, first_at: 3.days.ago, last_at: 1.day.ago)
                       .update!(is_contributor: false)
      participation_for(topic, source, message_count: 1, first_at: 10.days.ago, last_at: 2.days.ago)

      merge

      expect(TopicParticipant.find_by(topic_id: topic.id, person_id: target.id).is_contributor).to be true
      expect(topic.reload.contributor_participant_count).to eq(1)
    end

    it "moves a row for a topic the target was not in" do
      source_alias = create(:alias, person: source, name: "Old Name", email: "old@example.com")
      create(:alias, person: target, name: "Kept Name", email: "kept@example.com")
      topic = create(:topic, creator_alias: source_alias)
      create(:message, topic: topic, sender_alias: source_alias)

      participation_for(topic, source, message_count: 4, first_at: 10.days.ago, last_at: 2.days.ago)

      merge

      row = TopicParticipant.find_by(topic_id: topic.id)
      expect(row.person_id).to eq(target.id)
      expect(row.message_count).to eq(4)
    end
  end

  describe "alias propagation" do
    it "queues a propagation job per moved alias, since update_all skips the hook" do
      moved = create(:alias, person: source, name: "Old Name", email: "old@example.com")
      create(:alias, person: target, name: "Kept Name", email: "kept@example.com")

      expect { merge }.to have_enqueued_job(PersonIdPropagationJob)
        .with(moved.id, target.id, source.id)
    end
  end

  describe "audit record" do
    it "captures the source snapshot and the moved counts" do
      source_alias = create(:alias, person: source, name: "Old Name", email: "old@example.com")
      create(:alias, person: target, name: "Kept Name", email: "kept@example.com")
      topic = create(:topic, creator_alias: source_alias)
      create(:message, topic: topic, sender_alias: source_alias)

      result = merge
      audit = result.person_merge

      expect(audit.performed_by).to eq(admin)
      expect(audit.source_person_id).to eq(source.id)
      expect(audit.target_person_id).to eq(target.id)
      expect(audit.source_name).to eq("Old Name")
      expect(audit.source_emails).to eq([ "old@example.com" ])
      expect(audit.aliases_moved).to eq(1)
      expect(audit.topics_moved).to eq(1)
      expect(audit.messages_moved).to eq(1)
    end
  end

  describe "validation" do
    it "refuses to merge a person into itself" do
      result = merge(target_person: source)

      expect(result.success?).to be false
      expect(result.error).to match(/into itself/)
    end

    it "refuses when the source has a user account" do
      registered = create(:user, username: "registered_user")

      result = merge(source_person: registered.person)

      expect(result.success?).to be false
      expect(result.error).to match(/user account/)
      expect(Person.find_by(id: registered.person_id)).to be_present
    end

    it "refuses when both sides have user accounts" do
      one = create(:user, username: "user_one")
      two = create(:user, username: "user_two")

      result = merge(source_person: one.person, target_person: two.person)

      expect(result.success?).to be false
      expect(result.error).to match(/user account/)
    end

    it "allows merging into a person that has a user account" do
      registered = create(:user, username: "registered_target")
      create(:alias, person: source, name: "Old Name", email: "old@example.com")

      result = merge(target_person: registered.person)

      expect(result.success?).to be true
      expect(Person.find_by(id: source.id)).to be_nil
    end

    it "rejects a non-admin actor" do
      result = merge(merged_by: create(:user, username: "not_an_admin"))

      expect(result.success?).to be false
      expect(result.error).to match(/admin/)
    end
  end

  describe "#preview" do
    it "reports what would move without writing anything" do
      create(:alias, person: source, name: "Old Name", email: "old@example.com", sender_count: 3)
      create(:alias, person: target, name: "Kept Name", email: "kept@example.com", sender_count: 7)

      preview = described_class.new(
        source_person: source, target_person: target, merged_by: admin
      ).preview

      expect(preview[:source][:name]).to eq("Old Name")
      expect(preview[:source][:emails]).to eq([ "old@example.com" ])
      expect(preview[:target][:message_count]).to eq(7)
      expect(preview[:moves][:aliases]).to eq(1)
      expect(Person.find_by(id: source.id)).to be_present
    end
  end

  describe "#validation_error" do
    it "returns nil for a valid merge" do
      service = described_class.new(source_person: source, target_person: target, merged_by: admin)

      expect(service.validation_error).to be_nil
    end

    it "returns the message for an invalid merge" do
      service = described_class.new(source_person: source, target_person: source, merged_by: admin)

      expect(service.validation_error).to match(/into itself/)
    end
  end
end
