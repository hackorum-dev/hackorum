require "rails_helper"

RSpec.describe FeatureGroups::Versions do
  before do
    Classify::Setup.call!
    {
      "REL_17_BETA1" => "2024-05-21", "REL_17_0" => "2024-09-23",
      "REL_18_BETA1" => "2025-05-05", "REL_18_0" => "2025-09-22",
      "REL_19_BETA1" => "2026-06-01"
    }.each { |name, at| tag(name, at) }
  end

  def all_stable = %w[REL_17_STABLE REL_18_STABLE REL_19_STABLE master]

  def tag(name, at)
    create(:release_tag, name: name, released_at: Time.zone.parse(at))
  end

  def thread(*tags)
    create(:topic).tap { |topic| Classify::BotNote.new(topic).write!(tags) }
  end

  def commit_on(topic, at, branches, subject: "Add a thing", body: "", from: nil)
    commit = create(:commit, committed_at: Time.zone.parse(at), branches: branches,
                             subject: subject, body: body, cherry_picked_from_sha: from&.sha)
    create(:commit_topic, commit: commit, topic: topic) if topic
    commit
  end

  def statuses(topic_ids)
    described_class.compute(Array(topic_ids)).transform_values { |v| v[:status] }
  end

  describe ".compute" do
    it "marks MERGE/SPLIT PARTITION reverted in 17 and 19" do
      feature = thread("feature", "moderate")
      f1 = commit_on(feature, "2024-04-06", all_stable, subject: "Implement ALTER TABLE ... MERGE PARTITIONS ... command")
      fix1 = commit_on(feature, "2024-04-09", all_stable, subject: "Checks for ALTER TABLE ... SPLIT/MERGE PARTITIONS ... commands")
      revert = "Revert support for ALTER TABLE ... MERGE/SPLIT PARTITION(S) commands"
      body1 = "This commit reverts #{f1.sha[0, 10]}, and subsequent fixes and\nimprovements including #{fix1.sha[0, 10]}.\n"
      r1 = commit_on(feature, "2024-08-24", %w[REL_18_STABLE REL_19_STABLE master], subject: revert, body: body1)
      r1b = commit_on(feature, "2024-08-24", %w[REL_17_STABLE], subject: revert, body: body1, from: r1)
      f2 = commit_on(feature, "2025-12-14", %w[REL_19_STABLE master], subject: "Implement ALTER TABLE ... MERGE PARTITIONS ... command")
      body2 = "This commit reverts #{f2.sha[0, 10]} and the subsequent fixes.\n"
      r2 = commit_on(feature, "2026-08-26", %w[master], subject: revert, body: body2)
      commit_on(feature, "2026-08-27", %w[REL_19_STABLE], subject: revert, body: body2, from: r2)

      result = described_class.compute([ feature.id ])

      expect(result.transform_values { _1[:status] }).to eq(17 => "reverted", 19 => "reverted")
      expect(result[17][:commit_ids]).to match_array([ f1.id, fix1.id, r1.id, r1b.id ])
    end

    it "ships a released major and develops the unreleased ones" do
      tag("REL_19_0", "2026-11-16")
      feature = thread("feature", "major")
      a = commit_on(feature, "2026-01-10", %w[REL_19_STABLE master])
      b = commit_on(feature, "2026-09-01", %w[master])

      result = described_class.compute([ feature.id ])

      expect(result.transform_values { _1.slice(:status, :commit_ids) }).to eq(
        19 => { status: "shipped", commit_ids: [ a.id ] },
        20 => { status: "in-development", commit_ids: [ b.id ] }
      )
    end

    it "keeps a major in development until GA" do
      feature = thread("performance", "minor")
      commit_on(feature, "2026-01-10", %w[REL_19_STABLE master])

      expect(statuses(feature.id)).to eq(19 => "in-development")
    end

    it "places a master-only change by the cycle it landed in" do
      feature = thread("feature", "minor")
      commit_on(feature, "2026-05-20", %w[master])

      expect(statuses(feature.id)).to eq(19 => "in-development")
    end

    it "ignores cherry-picked fixes and bug threads" do
      feature = thread("feature", "moderate")
      bug = thread("bug")
      commit_on(feature, "2026-01-10", %w[REL_19_STABLE master])
      fix = commit_on(feature, "2026-09-01", %w[master], subject: "Fix crash in the thing")
      commit_on(feature, "2026-09-01", %w[REL_19_STABLE], subject: fix.subject, from: fix)
      commit_on(bug, "2026-09-02", %w[master])

      expect(statuses([ feature.id, bug.id ])).to eq(19 => "in-development")
    end

    it "reports worked-on from activity without commits" do
      feature = thread("feature", "moderate")
      bug = thread("bug")
      create(:message, topic: feature, created_at: Time.zone.parse("2025-06-10"))
      create(:message, topic: feature, created_at: Time.zone.parse("2026-09-01"))
      create(:message, topic: bug, created_at: Time.zone.parse("2024-06-10"))
      commit_on(feature, "2026-09-01", %w[master])

      expect(statuses([ feature.id, bug.id ])).to eq(19 => "worked-on", 20 => "in-development")
    end

    it "reverts within the development major" do
      feature = thread("feature", "major")
      f = commit_on(feature, "2026-09-01", %w[master])
      r = commit_on(feature, "2026-10-01", %w[master], subject: "Revert \"#{f.subject}\"", body: "This reverts commit #{f.sha}.")

      expect(described_class.compute([ feature.id ])[20]).to include(status: "reverted", commit_ids: [ f.id, r.id ])
    end

    it "does not count a revert of a single fix" do
      feature = thread("feature", "moderate")
      commit_on(feature, "2026-01-10", %w[REL_19_STABLE master])
      fixes = Array.new(3) { |i| commit_on(feature, "2026-02-1#{i}", %w[REL_19_STABLE master]) }
      commit_on(feature, "2026-03-01", %w[REL_19_STABLE master],
                subject: "Revert \"#{fixes[1].subject}\"", body: "This reverts commit #{fixes[1].sha}.")

      expect(statuses(feature.id)).to eq(19 => "in-development")
    end

    it "does not count a fix revert when N has two changes" do
      feature = thread("feature", "moderate")
      commit_on(feature, "2026-01-10", %w[REL_19_STABLE master])
      fix = commit_on(feature, "2026-02-10", %w[REL_19_STABLE master], subject: "Fix thing")
      revert = commit_on(feature, "2026-09-01", %w[master], subject: "Revert \"Fix thing\"", body: "This reverts commit #{fix.sha}.")
      commit_on(feature, "2026-09-01", %w[REL_19_STABLE], subject: revert.subject, body: revert.body, from: revert)

      expect(statuses(feature.id)).to eq(19 => "in-development")
    end

    it "reverts the development major when each change is reverted on its own" do
      feature = thread("feature", "moderate")
      f1 = commit_on(feature, "2026-09-01", %w[master])
      f2 = commit_on(feature, "2026-09-05", %w[master])
      commit_on(feature, "2026-10-01", %w[master], subject: "Revert f1", body: "This reverts commit #{f1.sha}.")
      commit_on(feature, "2026-10-02", %w[master], subject: "Revert f2", body: "This reverts commit #{f2.sha}.")

      expect(statuses(feature.id)).to eq(20 => "reverted")
    end

    it "does not create a row from a lone revert" do
      feature = thread("feature", "moderate")
      old = commit_on(feature, "2025-01-10", %w[REL_18_STABLE REL_19_STABLE master])
      commit_on(feature, "2026-10-01", %w[master], subject: "Revert old thing", body: "This reverts commit #{old.sha}.")

      expect(statuses(feature.id)).to eq(18 => "shipped")
    end

    it "does not mark reverted when the feature landed again" do
      feature = thread("feature", "moderate")
      f1 = commit_on(feature, "2026-01-10", %w[REL_19_STABLE master])
      commit_on(feature, "2026-02-01", %w[REL_19_STABLE master], subject: "Revert the thing", body: "Reverts #{f1.sha[0, 7]}.")
      commit_on(feature, "2026-03-01", %w[REL_19_STABLE master])

      expect(statuses(feature.id)).to eq(19 => "in-development")
    end

    it "skips changes from majors before 10" do
      feature = thread("feature", "moderate")
      commit_on(feature, "2016-01-10", %w[REL9_6_STABLE REL_10_STABLE master])

      expect(statuses(feature.id)).to eq({})
    end

    it "returns nothing for untagged threads" do
      topic = create(:topic)
      commit_on(topic, "2026-01-10", %w[REL_19_STABLE master])

      expect(described_class.compute([ topic.id ])).to eq({})
    end
  end

  describe ".compute details" do
    def detail(topic_ids, major) = described_class.compute(Array(topic_ids))[major]

    it "lists sized threads, largest size, and new role when any thread is not an enhancement" do
      f1 = thread("feature", "major")
      f2 = thread("feature", "minor", "enhancement")
      commit_on(f1, "2026-01-10", %w[REL_19_STABLE master])
      commit_on(f2, "2026-01-11", %w[REL_19_STABLE master])

      expect(detail([ f1.id, f2.id ], 19)).to include(size: "major", role: "new", topic_ids: [ f1.id, f2.id ].sort, changes: 2)
    end

    it "is improved when only enhancement threads contribute" do
      f = thread("performance", "moderate", "enhancement")
      commit_on(f, "2026-01-10", %w[REL_19_STABLE master])

      expect(detail(f.id, 19)).to include(role: "improved", size: "moderate")
    end

    it "excludes non-sized threads from topic_ids" do
      f = thread("feature", "minor")
      bug = thread("bug")
      c = commit_on(f, "2026-01-10", %w[REL_19_STABLE master])
      create(:commit_topic, commit: c, topic: bug)

      expect(detail([ f.id, bug.id ], 19)[:topic_ids]).to eq([ f.id ])
    end

    it "sums lines per change and leaves cherry-picked pairs out" do
      f = thread("feature", "moderate")
      orig = commit_on(f, "2026-09-01", %w[master])
      orig.update!(lines_added: 100, lines_removed: 10)
      commit_on(nil, "2026-09-02", %w[REL_19_STABLE], subject: orig.subject, from: orig).update!(lines_added: 90, lines_removed: 9)
      commit_on(f, "2026-09-05", %w[REL_19_STABLE master]).update!(lines_added: 5, lines_removed: nil)
      commit_on(f, "2026-09-06", %w[REL_19_STABLE master]).update!(lines_added: 7, lines_removed: 3)

      expect(detail(f.id, 19)).to include(changes: 2, lines_added: 12, lines_removed: 3)
    end

    it "uses nil lines when no commit has line data" do
      f = thread("feature", "moderate")
      commit_on(f, "2026-09-01", %w[master])

      expect(detail(f.id, 20)).to include(lines_added: nil, lines_removed: nil)
    end

    it "lists active sized threads for worked-on with no changes" do
      f = thread("feature", "moderate", "enhancement")
      bug = thread("bug")
      create(:message, topic: f, created_at: Time.zone.parse("2025-06-10"))
      create(:message, topic: bug, created_at: Time.zone.parse("2025-06-10"))

      expect(detail([ f.id, bug.id ], 19)).to include(status: "worked-on", topic_ids: [ f.id ], changes: 0,
                                                       size: "moderate", role: "improved", lines_added: nil)
    end
  end

  describe ".refresh!" do
    let(:group) { create(:feature_group) }
    let(:feature) { thread("feature", "major") }

    before do
      create(:feature_group_topic, feature_group: group, topic: feature)
    end

    it "keeps human rows on refresh" do
      commit_on(feature, "2026-01-10", %w[REL_19_STABLE master])
      b = commit_on(feature, "2026-09-01", %w[master])
      create(:feature_group_version, feature_group: group, major: 19, status: "shipped", source: "human")
      create(:feature_group_version, feature_group: group, major: 16, status: "shipped", source: "computed")

      described_class.refresh!([ group.id ])

      rows = group.feature_group_versions.order(:major)
      expect(rows.pluck(:major, :status, :source)).to eq([ [ 19, "shipped", "human" ], [ 20, "in-development", "computed" ] ])
      expect(rows.last.details).to include("commit_ids" => [ b.id ], "changes" => 1)
    end

    it "keeps admin status and role on a human row but refreshes details" do
      a = commit_on(feature, "2026-01-10", %w[REL_19_STABLE master])
      create(:feature_group_version, feature_group: group, major: 19, status: "shipped", role: "new", source: "human",
                                     details: { "commit_ids" => [] })
      create(:feature_group_version, feature_group: group, major: 12, status: "shipped", role: "new", source: "human")

      described_class.refresh!([ group.id ])

      row = group.feature_group_versions.find_by(major: 19)
      expect(row).to have_attributes(status: "shipped", role: "new", source: "human")
      expect(row.details).to include("commit_ids" => [ a.id ], "changes" => 1, "topic_ids" => [ feature.id ])
      expect(group.feature_group_versions.find_by(major: 12)).to have_attributes(status: "shipped", role: "new")
    end

    it "clears details of a human row whose major is no longer computed" do
      commit_on(feature, "2026-01-10", %w[REL_19_STABLE master])
      create(:feature_group_version, feature_group: group, major: 12, status: "shipped", source: "human",
                                     details: { "commit_ids" => [ 1 ] })

      described_class.refresh!([ group.id ])

      expect(group.feature_group_versions.find_by(major: 12)).to have_attributes(status: "shipped", details: nil)
    end

    it "stores role and details on computed rows" do
      commit_on(feature, "2026-01-10", %w[REL_19_STABLE master])

      described_class.refresh!([ group.id ])

      row = group.feature_group_versions.find_by(major: 19)
      expect(row.role).to eq("new")
      expect(row.details).to include("size" => "major", "lines_added" => nil, "lines_removed" => nil)
    end

    it "updates a computed row in place" do
      commit_on(feature, "2026-01-10", %w[REL_19_STABLE master])
      row = create(:feature_group_version, feature_group: group, major: 19, status: "worked-on", source: "computed")

      described_class.refresh!([ group.id ])

      expect(row.reload.status).to eq("in-development")
    end
  end

  describe ".refresh_for_commits!" do
    it "refreshes groups linked through any member of the change" do
      group = create(:feature_group)
      other = create(:feature_group)
      feature = thread("feature", "major")
      create(:feature_group_topic, feature_group: group, topic: feature)
      original = commit_on(feature, "2026-09-01", %w[master])
      backport = commit_on(nil, "2026-09-01", %w[REL_19_STABLE], subject: original.subject, from: original)
      create(:feature_group_version, feature_group: group, major: 16, status: "shipped", source: "computed")
      create(:feature_group_version, feature_group: other, major: 16, status: "shipped", source: "computed")

      described_class.refresh_for_commits!([ backport.id ])

      expect(group.feature_group_versions).to be_empty
      expect(other.feature_group_versions.count).to eq(1)
    end
  end

  describe ".refresh_unreleased!" do
    it "recomputes groups with in-development rows" do
      group = create(:feature_group)
      done = create(:feature_group)
      feature = thread("feature", "major")
      create(:feature_group_topic, feature_group: group, topic: feature)
      commit_on(feature, "2026-01-10", %w[REL_19_STABLE master])
      described_class.refresh!([ group.id ])
      stale = create(:feature_group_version, feature_group: done, major: 16, status: "shipped", source: "computed")
      tag("REL_19_0", "2026-11-16")

      described_class.refresh_unreleased!

      expect(group.feature_group_versions.pluck(:major, :status)).to eq([ [ 19, "shipped" ] ])
      expect(FeatureGroupVersion.exists?(stale.id)).to be(true)
    end
  end
end
