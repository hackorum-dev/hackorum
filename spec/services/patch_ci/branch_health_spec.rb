require "rails_helper"

RSpec.describe PatchCi::BranchHealth do
  let(:repo_state) { create(:patch_ci_repo_state, master_committed_at: Time.current) }
  let(:health) { described_class.new(repo_state: repo_state) }

  def stale_time
    repo_state.master_committed_at - (PatchCi::Config::REBASE_AFTER_DAYS + 5).days
  end

  def fresh_time
    repo_state.master_committed_at - 1.day
  end

  # base_sha defaults to the current master, the way on_master defaults to true:
  # both say "this row applied on master", and the applies arm reads both
  def branch(status: "applied", **attrs)
    attrs = { base_sha: repo_state.master_sha }.merge(attrs)
    create(:patch_branch, topic: create(:topic), status: status, **attrs)
  end

  def count_queries
    count = 0
    callback = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" }
    result = nil
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { result = yield }
    [ count, result ]
  end

  # the health panel lays its columns out by iterating this, so the sequence is
  # UI, not just a set
  it "keeps the bucket order the dashboard panel renders in" do
    expect(described_class::BUCKETS)
      .to eq(%w[applies needs_rebase awaiting_ci wont_retry never_applied])
  end

  describe "bucket boundaries" do
    it "ci_status ci_none is wont_retry" do
      row = branch(ci_status: "ci_none")
      expect(health.bucket_for(row)).to eq("wont_retry")
    end

    it "topic with a committed commit is wont_retry" do
      row = branch
      create(:commit_topic, topic: row.topic)
      expect(health.bucket_for(row)).to eq("wont_retry")
    end

    it "merged topic is wont_retry" do
      row = branch(pushed_at: Time.current, ci_status: "success", base_committed_at: fresh_time)
      row.topic.update_columns(merged_into_topic_id: create(:topic).id)
      expect(health.bucket_for(row)).to eq("wont_retry")
    end

    # the arm reads status alone - no stage is retryable, so none of them is a
    # boundary of its own
    it "failed is never_applied whatever the stage" do
      PatchBranch::FAILURE_STAGES.each do |stage|
        row = branch(status: "failed", failure_stage: stage)
        expect(health.bucket_for(row)).to eq("never_applied"), "failure_stage #{stage}"
      end
    end

    it "failed but topic has a committed commit is wont_retry (committed wins over failed)" do
      row = branch(status: "failed", failure_stage: "apply")
      create(:commit_topic, topic: row.topic)
      expect(health.bucket_for(row)).to eq("wont_retry")
    end

    it "failed but topic merged is wont_retry (merged wins over failed)" do
      row = branch(status: "failed", failure_stage: "apply")
      row.topic.update_columns(merged_into_topic_id: create(:topic).id)
      expect(health.bucket_for(row)).to eq("wont_retry")
    end

    it "applied but not pushed is awaiting_ci" do
      row = branch(pushed_at: nil)
      expect(health.bucket_for(row)).to eq("awaiting_ci")
    end

    it "not pushed on an ancient base is still awaiting_ci - a push is owed before any verdict" do
      row = branch(pushed_at: nil, base_committed_at: stale_time)
      expect(health.bucket_for(row)).to eq("awaiting_ci")
    end

    it "pushed and running is awaiting_ci" do
      row = branch(pushed_at: Time.current, ci_status: "running", base_committed_at: fresh_time)
      expect(health.bucket_for(row)).to eq("awaiting_ci")
    end

    it "pushed and pushed_awaiting_ci is awaiting_ci" do
      row = branch(pushed_at: Time.current, ci_status: "pushed_awaiting_ci",
                    base_committed_at: fresh_time)
      expect(health.bucket_for(row)).to eq("awaiting_ci")
      expect(health.scope_for("awaiting_ci").pluck(:id)).to include(row.id)
    end

    # on_master is the conflict signal, not master_apply_error: the detected-base
    # path is only reached after master has already failed, so the 2026 backfill's
    # rows carry the answer even though the error column was added later
    it "pushed on a non-master base is needs_rebase, with no error column set" do
      row = branch(pushed_at: Time.current, ci_status: "success",
                    base_committed_at: fresh_time, on_master: false, master_apply_error: nil)
      expect(health.bucket_for(row)).to eq("needs_rebase")
    end

    it "pushed with a stale base is wont_retry, whatever the last outcome was" do
      row = branch(pushed_at: Time.current, ci_status: "success",
                    base_committed_at: stale_time, on_master: true)
      expect(health.bucket_for(row)).to eq("wont_retry")
    end

    it "pushed with nil base_committed_at is needs_rebase - unjudgeable, so still retryable" do
      row = branch(pushed_at: Time.current, ci_status: "success", base_committed_at: nil)
      expect(health.bucket_for(row)).to eq("needs_rebase")
    end

    it "pushed on master with a recent base is applies" do
      row = branch(pushed_at: Time.current, ci_status: "success",
                    base_committed_at: fresh_time, on_master: true)
      expect(health.bucket_for(row)).to eq("applies")
    end

    # master moves several times a day, so a base that is not the tip is the
    # normal state of a healthy row and says nothing about whether the patch
    # still applies. Only a failed attempt is a verdict.
    it "pushed on a base master has moved past is still applies" do
      row = branch(pushed_at: Time.current, ci_status: "success",
                    base_committed_at: fresh_time, on_master: true, base_sha: "f" * 40)
      expect(health.bucket_for(row)).to eq("applies")
    end

    it "needs_rebase once an attempt on master has actually failed" do
      row = branch(pushed_at: Time.current, ci_status: "success",
                    base_committed_at: fresh_time, on_master: true, base_sha: "f" * 40,
                    master_apply_sha: repo_state.master_sha,
                    master_apply_error: "CONFLICT (content): Merge conflict in a.c")
      expect(health.bucket_for(row)).to eq("needs_rebase")
    end
  end

  describe "#counts" do
    it "matches the exact bucket for each row in a mixed population" do
      branch(ci_status: "ci_none")
      branch(status: "failed", failure_stage: "apply")
      branch(status: "failed", failure_stage: "extract")
      branch(pushed_at: nil)
      branch(pushed_at: Time.current, ci_status: "queued", base_committed_at: fresh_time)
      branch(pushed_at: Time.current, ci_status: "success",
             base_committed_at: fresh_time, on_master: false)
      branch(pushed_at: Time.current, ci_status: "success",
             base_committed_at: fresh_time, on_master: true)

      expect(health.counts).to eq(
        "applies" => 1,
        "needs_rebase" => 1,
        "awaiting_ci" => 2,
        "wont_retry" => 1,
        "never_applied" => 2
      )
      expect(health.counts.values.sum).to eq(PatchBranch.current.count)
    end
  end

  describe "#failing_on_current_master" do
    # a failure is only news if it was reached against the master we have: the
    # same row failing against last week's master is a stale answer, which is
    # what the rebase tier is for
    it "keeps the rows whose failure was against this master" do
      fresh = branch(pushed_at: Time.current, ci_status: "success",
                     base_committed_at: fresh_time, base_sha: "f" * 40,
                     master_apply_sha: repo_state.master_sha,
                     master_apply_error: "CONFLICT (content): a.c")
      branch(pushed_at: Time.current, ci_status: "success",
             base_committed_at: fresh_time, base_sha: "e" * 40,
             master_apply_sha: "0" * 40, master_apply_error: "CONFLICT (content): a.c")
      # never reached master at all: no sha, so nothing to trust
      branch(pushed_at: Time.current, ci_status: "success",
             base_committed_at: fresh_time, base_sha: "d" * 40, on_master: false)

      ids = health.failing_on_current_master(health.scope_for("needs_rebase")).pluck(:id)

      expect(ids).to contain_exactly(fresh.id)
    end
  end

  describe "#scope_for" do
    it "returns the rows matching the bucket" do
      matching = branch(pushed_at: nil)
      branch(ci_status: "ci_none")

      expect(health.scope_for("awaiting_ci").pluck(:id)).to contain_exactly(matching.id)
    end

    it "accepts a symbol bucket name" do
      matching = branch(pushed_at: Time.current, ci_status: "success",
                         base_committed_at: fresh_time)

      expect(health.scope_for(:applies).pluck(:id)).to include(matching.id)
    end

    it "raises ArgumentError with the bad value in the message for an unknown bucket" do
      expect { health.scope_for("bogus") }.to raise_error(ArgumentError, 'unknown bucket: "bogus"')
    end
  end

  describe "#filter" do
    it "accepts several buckets and joins topics itself" do
      not_pushed = branch(pushed_at: nil)
      skipped = branch(ci_status: "ci_none")
      branch(pushed_at: Time.current, ci_status: "success", base_committed_at: fresh_time)

      ids = health.filter(PatchBranch.current, [ "awaiting_ci", "wont_retry" ]).pluck(:id)

      expect(ids).to match_array([ not_pushed.id, skipped.id ])
    end

    it "returns the relation untouched for an empty list" do
      rows = [ branch(pushed_at: nil), branch(ci_status: "ci_none") ]

      expect(health.filter(PatchBranch.current, []).pluck(:id)).to match_array(rows.map(&:id))
    end

    # unlike scope_for, which raises: this one takes user input off a URL, and a
    # bookmark holding a bucket name we have since renamed must not 500
    it "drops unknown bucket names instead of raising" do
      row = branch(pushed_at: nil)

      expect(health.filter(PatchBranch.current, [ "bogus" ]).pluck(:id)).to eq([ row.id ])
      expect(health.filter(PatchBranch.current, [ "fresh" ]).pluck(:id)).to eq([ row.id ])
      expect(health.filter(PatchBranch.current, [ "awaiting_ci", "bogus" ]).pluck(:id)).to eq([ row.id ])
    end
  end

  describe "#bucket_for" do
    it "agrees with counts" do
      rows = [
        branch(ci_status: "ci_none"),
        branch(status: "failed", failure_stage: "apply"),
        branch(pushed_at: Time.current, ci_status: "success", base_committed_at: fresh_time)
      ]

      counts = health.counts
      tally = rows.group_by { |row| health.bucket_for(row) }.transform_values(&:count)
      expect(counts).to eq(described_class::BUCKETS.index_with { |b| tally.fetch(b, 0) })
    end
  end

  describe "#with_bucket" do
    it "adds a health_bucket column agreeing with bucket_for, in one query" do
      rows = [
        branch(ci_status: "ci_none"),
        branch(status: "failed", failure_stage: "apply"),
        branch(pushed_at: Time.current, ci_status: "success", base_committed_at: fresh_time)
      ]
      expected = rows.index_by(&:id).transform_values { |row| health.bucket_for(row) }

      queries, result = count_queries { health.with_bucket.where(id: rows.map(&:id)).to_a }

      expect(queries).to eq(1)
      result.each { |row| expect(row.health_bucket).to eq(expected[row.id]) }
    end
  end

  describe "#wont_retry_breakdown" do
    it "labels committed / ci_skip_reason / base too old, sorted desc" do
      3.times do
        branch(pushed_at: Time.current, ci_status: "success", base_committed_at: stale_time)
      end
      2.times do
        row = branch
        create(:commit_topic, topic: row.topic)
      end
      branch(ci_status: "ci_none", ci_skip_reason: "push failed: timeout")

      breakdown = health.wont_retry_breakdown
      expect(breakdown).to eq(
        "base too old" => 3,
        "committed" => 2,
        "push failed: timeout" => 1
      )
      expect(breakdown.to_a).to eq(
        [ [ "base too old", 3 ], [ "committed", 2 ], [ "push failed: timeout", 1 ] ]
      )
    end

    it "labels a merged topic as merged thread" do
      row = branch(pushed_at: Time.current, ci_status: "success", base_committed_at: fresh_time)
      row.topic.update_columns(merged_into_topic_id: create(:topic).id)

      expect(health.wont_retry_breakdown).to eq("merged thread" => 1)
    end

    it "falls back to the 'ci_none' label when ci_skip_reason is nil" do
      branch(ci_status: "ci_none", ci_skip_reason: nil)

      expect(health.wont_retry_breakdown).to eq("ci_none" => 1)
    end

    it "labels a row that is both ci_none and committed by ci_none (matches bucket_sql's own precedence)" do
      row = branch(ci_status: "ci_none", ci_skip_reason: "custom reason")
      create(:commit_topic, topic: row.topic)

      expect(health.wont_retry_breakdown).to eq("custom reason" => 1)
    end
  end

  describe "nil repo_state" do
    it "does not raise, using WORK_FROM as the stale cutoff" do
      health_no_repo = described_class.new(repo_state: nil)
      branch(pushed_at: Time.current, ci_status: "success", base_committed_at: 1.year.ago)

      expect { health_no_repo.counts }.not_to raise_error
    end

    it "classifies a pushed row with a normal past base as applies under the WORK_FROM fallback" do
      health_no_repo = described_class.new(repo_state: nil)
      row = branch(pushed_at: Time.current, ci_status: "success", base_committed_at: 3.days.ago)

      expect(health_no_repo.bucket_for(row)).to eq("applies")
    end

    it "classifies a pushed nil-meta row as needs_rebase under the WORK_FROM fallback" do
      health_no_repo = described_class.new(repo_state: nil)
      row = branch(pushed_at: Time.current, ci_status: "success", base_committed_at: nil)

      expect(health_no_repo.bucket_for(row)).to eq("needs_rebase")
    end
  end

  describe "#with_reason" do
    def reason_for(row)
      health.with_reason(PatchBranch.where(id: row.id)).first.wont_retry_reason
    end

    it "labels a committed thread" do
      row = branch
      create(:commit_topic, topic: row.topic)

      expect(reason_for(row)).to eq("committed")
    end

    it "labels a merged thread" do
      row = branch
      row.topic.update!(merged_into_topic: create(:topic))

      expect(reason_for(row)).to eq("merged thread")
    end

    it "carries the skip reason of a ci_none row" do
      row = branch(ci_status: "ci_none", ci_skip_reason: "push failed: timeout")

      expect(reason_for(row)).to eq("push failed: timeout")
    end

    it "labels an aged out base" do
      row = branch(base_committed_at: stale_time)

      expect(reason_for(row)).to eq("base too old")
    end

    # the icon reads this column and wont_retry_breakdown reads the same CASE;
    # a second copy of it is how they would start naming the same row two things.
    # Mixed population on purpose: both sides must agree on which rows are even
    # in scope, not just on what the retired ones are called.
    it "agrees with wont_retry_breakdown over a mixed population" do
      branch(ci_status: "ci_none", ci_skip_reason: "custom reason")
      committed = branch
      create(:commit_topic, topic: committed.topic)
      branch(pushed_at: Time.current, ci_status: "success", base_committed_at: fresh_time)

      expect(health.with_reason(health.scope_for("wont_retry")).map(&:wont_retry_reason))
        .to match_array(health.wont_retry_breakdown.keys)
    end
  end
end
