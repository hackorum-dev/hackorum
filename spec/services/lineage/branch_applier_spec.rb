require "rails_helper"

RSpec.describe Lineage::BranchApplier do
  include PatchSeriesHelper

  let(:patchset) { Lineage::PatchsetEnumerator::Patchset }

  it "applies missing patchsets as lineage_only and reuses existing rows" do
    Dir.mktmpdir do |dir|
      fixture = GitFixtureRepo.new(File.join(dir, "repo"))
      base = fixture.commit(subject: "base", files: { "a.txt" => "one\n" })
      patch_dir = File.join(dir, "patches")
      FileUtils.mkdir_p(patch_dir)
      patch = generate_patch(fixture.path, base, "a.txt", "two\n", patch_dir)

      topic = create(:topic)
      m1 = create(:message, topic: topic, is_patch_submission: true, created_at: 2.days.ago)
      create(:attachment, message: m1, file_name: "0001-x.patch", body: Base64.encode64(File.binread(patch)))
      m2 = create(:message, topic: topic, is_patch_submission: true, created_at: 1.day.ago)
      existing = create(:patch_branch, topic: topic, message: m2, base_sha: "deadbeef", status: "applied")
      m3 = create(:message, topic: topic, is_patch_submission: true, created_at: 1.hour.ago)

      m4 = create(:message, topic: topic, is_patch_submission: false, created_at: 30.minutes.ago)
      sets = [ patchset.new(message: m1.reload, parse_error: nil), patchset.new(message: m2, parse_error: nil),
               patchset.new(message: m3, parse_error: "broken"), patchset.new(message: m4, nocfbot: true) ]
      report = described_class.new(repo_path: fixture.path, worktrees_dir: File.join(dir, "wt")).call(sets)

      expect(report[m1.id][:status]).to eq("applied")
      expect(report[m1.id][:lineage_only]).to be(true)
      expect(report[m2.id][:base_sha]).to eq("deadbeef")
      expect(PatchBranch.find_by(message_id: m2.id)).to eq(existing)
      expect(report[m3.id]).to eq({ status: "not_attempted" })
      expect(report[m4.id]).to eq({ status: "not_attempted", reason: "nocfbot" })
      expect(PatchBranch.find_by(message_id: m4.id)).to be_nil
    end
  end

  describe "crashes" do
    let(:message) { create(:message, is_patch_submission: true) }
    let(:sets) { [ patchset.new(message: message, parse_error: nil) ] }
    let(:applier) { described_class.new(repo_path: "/unused", worktrees_dir: "/unused/wt") }

    before do
      repo = instance_double(PatchBranches::GitRepo, rev_parse: "abc", dir: "/unused")
      allow(PatchBranches::GitRepo).to receive(:new).and_return(repo)
      allow(repo).to receive(:ensure_worktree!)
      allow_any_instance_of(PatchBranches::ApplyOne).to receive(:call).and_raise("boom")
    end

    it "reports the persisted failed row" do
      allow_any_instance_of(PatchBranches::ApplyOne).to receive(:persist_error).and_return(nil)
      allow_any_instance_of(PatchBranches::ApplyOne).to receive(:record) do
        create(:patch_branch, message: message, status: "failed", failure_stage: "error")
      end

      expect(applier.call(sets)[message.id]).to include(status: "failed", failure_stage: "error")
    end

    it "reports an error when nothing was saved" do
      allow_any_instance_of(PatchBranches::ApplyOne).to receive(:persist_error).and_return(StandardError.new("db"))
      allow_any_instance_of(PatchBranches::ApplyOne).to receive(:record).and_return(PatchBranch.new)

      expect(applier.call(sets)[message.id]).to eq({ status: "error", error: "RuntimeError: boom" })
    end
  end
end
