require "rails_helper"

RSpec.describe Classify::SeedExport do
  it "emits one row per window topic" do
    create(:release_tag, name: "REL_16_BETA1", released_at: Time.zone.parse("2024-05-21"))
    ml = create(:mailing_list, identifier: "pgsql-hackers")
    topic = create(:topic, title: "Add foo")
    other = create(:topic)
    topic.update_columns(last_message_at: 1.month.ago)
    create(:topic_mailing_list, topic: topic, mailing_list: ml)
    create(:message, topic: topic, body: "> quoted\nHello there", created_at: 2.days.ago)
    create(:message, topic: topic, is_patch_submission: true, created_at: 1.day.ago)
    create(:topic_link, topic: topic, other_topic: other)
    cp = create(:commitfest_patch, title: "Foo patch", topic: "Replication")
    create(:commitfest_patch_topic, commitfest_patch: cp, topic: topic)
    create(:commitfest_patch_tag, commitfest_patch: cp, commitfest_tag: create(:commitfest_tag, name: "Misc"))

    rows = described_class.rows.to_a
    expect(rows.size).to eq(1)
    expect(rows.first).to include(
      topic_id: topic.id, title: "Add foo", cf_name: "Foo patch", cf_topic: "Replication", cf_tags: "Misc",
      patch_messages: 1, linked_topic_ids: [ other.id ]
    )
    expect(rows.first[:opening]).to eq("Hello there")
  end

  describe "since and richer rows" do
    let!(:ml) { create(:mailing_list, identifier: "pgsql-hackers") }

    before { create(:release_tag, name: "REL_16_BETA1", released_at: Time.zone.parse("2024-05-21")) }

    def scoped_topic(last_at)
      t = create(:topic)
      create(:topic_mailing_list, topic: t, mailing_list: ml)
      t.update_columns(last_message_at: last_at)
      t
    end

    it "since includes topics the default window excludes" do
      old = scoped_topic(Time.zone.parse("2023-06-01"))
      recent = scoped_topic(1.day.ago)
      expect(described_class.rows.map { |r| r[:topic_id] }).to eq([ recent.id ])
      ids = described_class.rows(since: Time.zone.parse("2023-01-01")).map { |r| r[:topic_id] }
      expect(ids).to contain_exactly(old.id, recent.id)
      expect(described_class.rows(since: Time.zone.parse("2024-01-01")).map { |r| r[:topic_id] }).to eq([ recent.id ])
    end

    it "adds counts, months, commit subjects and current group" do
      topic = scoped_topic(1.day.ago)
      create(:message, topic: topic, created_at: Time.zone.parse("2024-02-10 12:00"))
      create(:message, topic: topic, created_at: Time.zone.parse("2024-03-05 12:00"))
      create(:message, topic: topic, created_at: Time.zone.parse("2024-07-20 12:00"))
      later = create(:commit, subject: "Second", committed_at: Time.zone.parse("2024-06-02"))
      earlier = create(:commit, subject: "First", committed_at: Time.zone.parse("2024-06-01"))
      create(:commit_topic, topic: topic, commit: later)
      create(:commit_topic, topic: topic, commit: earlier)
      target = create(:feature_group, name: "Target")
      merged = create(:feature_group, name: "Merged away")
      merged.merge_into!(target)
      create(:feature_group_topic, topic: topic, feature_group: merged)

      row = described_class.rows.to_a.first
      expect(row).to include(
        message_count: 3, first_at: "2024-02", last_at: "2024-07",
        commit_subjects: [ "First", "Second" ], current_group: "Target"
      )
    end

    it "lists a backpatched commit once" do
      topic = scoped_topic(1.day.ago)
      original = create(:commit, subject: "Orig", committed_at: Time.zone.parse("2024-06-01"))
      copy = create(:commit, subject: "Orig", committed_at: Time.zone.parse("2024-06-02"), cherry_picked_from_sha: original.sha)
      create(:commit_topic, topic: topic, commit: original)
      create(:commit_topic, topic: topic, commit: copy)

      expect(described_class.rows.to_a.first[:commit_subjects]).to eq([ "Orig" ])
    end

    it "caps subjects at 5 and handles no group or commits" do
      topic = scoped_topic(1.day.ago)
      create(:feature_group_topic, topic: topic, feature_group: nil)
      6.times { |i| create(:commit_topic, topic: topic, commit: create(:commit, committed_at: Time.zone.parse("2024-06-0#{i + 1}"))) }
      other = scoped_topic(1.day.ago)

      rows = described_class.rows.to_a.index_by { |r| r[:topic_id] }
      expect(rows[topic.id][:commit_subjects].size).to eq(5)
      expect(rows[topic.id][:current_group]).to be_nil
      expect(rows[other.id]).to include(message_count: 0, first_at: nil, last_at: nil, commit_subjects: [], current_group: nil)
    end
  end
end
