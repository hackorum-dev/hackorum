require "rails_helper"

RSpec.describe Lineage::PatchsetEnumerator do
  ENUM_PATCH = "diff --git a/src/backend/x.c b/src/backend/x.c\n--- a/src/backend/x.c\n+++ b/src/backend/x.c\n@@ -1,1 +1,2 @@\n a\n+b\n".freeze

  def patch_message(topic, at, body = ENUM_PATCH)
    m = create(:message, topic: topic, created_at: at, is_patch_submission: true)
    create(:attachment, message: m, file_name: "0001-x.patch", body: Base64.encode64(body))
    m
  end

  it "orders patchsets and numbers them like the thread" do
    topic = create(:topic)
    create(:message, topic: topic, created_at: 3.days.ago)
    first = patch_message(topic, 2.days.ago)
    create(:message, topic: topic, created_at: 1.day.ago)
    second = patch_message(topic, 1.hour.ago)

    Dir.mktmpdir do |dir|
      sets = described_class.new(topic).call(dir)
      expect(sets.map { |s| s.message.id }).to eq([ first.id, second.id ])
      expect(sets.map(&:ordinal)).to eq([ 2, 4 ])
      expect(Dir.exist?(File.join(dir, "002"))).to be(true)
      expect(sets.first.parsed.files.first.path).to eq("src/backend/x.c")
      expect(sets.first.parse_error).to be_nil
    end
  end

  it "includes nocfbot-only messages and flags them" do
    topic = create(:topic)
    normal = patch_message(topic, 2.days.ago)
    delta = create(:message, topic: topic, created_at: 1.day.ago)
    create(:attachment, message: delta, file_name: "fix.patch.nocfbot", body: Base64.encode64(ENUM_PATCH))

    Dir.mktmpdir do |dir|
      sets = described_class.new(topic).call(dir)
      expect(sets.map { |s| s.message.id }).to eq([ normal.id, delta.id ])
      expect(sets.map(&:nocfbot)).to eq([ false, true ])
      expect(sets.last.parse_error).to be_nil
    end
  end

  it "keeps nocfbot false and extracts every file of a mixed message" do
    topic = create(:topic)
    m = patch_message(topic, 1.day.ago)
    create(:attachment, message: m, file_name: "delta.patch.nocfbot", body: Base64.encode64(ENUM_PATCH))

    Dir.mktmpdir do |dir|
      set = described_class.new(topic).call(dir).first
      expect(set.nocfbot).to be(false)
      expect(set.files.map { |f| File.basename(f) }).to contain_exactly("0001-x.patch", "delta.patch.nocfbot")
    end
  end

  it "keeps a broken patchset with an error instead of raising" do
    topic = create(:topic)
    m = create(:message, topic: topic, is_patch_submission: true)
    create(:attachment, message: m, file_name: "x.patch.gz", body: Base64.encode64("not gzip"))

    Dir.mktmpdir do |dir|
      sets = described_class.new(topic).call(dir)
      expect(sets.size).to eq(1)
      expect(sets.first.parse_error).to include("decompression failed")
      expect(sets.first.parsed).to be_nil
    end
  end
end
