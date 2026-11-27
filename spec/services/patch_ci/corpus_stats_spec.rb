require "rails_helper"

RSpec.describe PatchCi::CorpusStats do
  let(:master_at) { Time.zone.parse("2026-07-20 12:00:00") }
  let(:repo_state) { create(:patch_ci_repo_state, master_committed_at: master_at, master_commit_height: 100_000) }

  def stats(active_only: false, state: repo_state)
    described_class.new(repo_state: state, active_only: active_only)
  end

  # base_committed_at is set explicitly in every example: the whole section is
  # about where a row lands on a history axis
  def branch(base_age_days: 1, active: true, **attrs)
    topic = create(:topic)
    row = create(:patch_branch, topic: topic,
                                base_committed_at: (base_age_days ? master_at - base_age_days.days : nil),
                                **attrs)
    topic.update_columns(last_message_at: active ? 1.day.ago : (PatchCi::Config::ACTIVE_THREAD_DAYS + 5).days.ago)
    row
  end

  def band_count(rows, band, series: "all")
    rows.find { |row| row[:band] == band && row[:series] == series }&.dig(:count)
  end

  describe "#base_age_distribution" do
    it "puts a base 12 hours old in <1d and one exactly a day old in 1-7d" do
      branch(base_age_days: 0.5)
      branch(base_age_days: 1)

      rows = stats.base_age_distribution
      expect(band_count(rows, "<1d")).to eq(1)
      expect(band_count(rows, "1-7d")).to eq(1)
    end

    it "puts a base 30 days old in 30-90d and one 29 days old in 7-30d" do
      branch(base_age_days: 29)
      branch(base_age_days: 30)

      rows = stats.base_age_distribution
      expect(band_count(rows, "7-30d")).to eq(1)
      expect(band_count(rows, "30-90d")).to eq(1)
    end

    it "puts a base older than five years in >5y" do
      branch(base_age_days: 2000)

      expect(band_count(stats.base_age_distribution, ">5y")).to eq(1)
    end

    it "puts a null base_committed_at in unknown" do
      branch(base_age_days: nil)

      expect(band_count(stats.base_age_distribution, "unknown")).to eq(1)
    end

    it "emits every band even when empty, so the histogram has no holes" do
      branch(base_age_days: 1)

      bands = stats.base_age_distribution.select { |row| row[:series] == "all" }.map { |row| row[:band] }
      expect(bands).to eq(PatchCi::Config::BASE_AGE_BUCKETS.map(&:first) + [ "unknown" ])
    end

    it "counts an active-discussion row in both series" do
      branch(base_age_days: 1, active: true)

      rows = stats.base_age_distribution
      expect(band_count(rows, "1-7d", series: "all")).to eq(1)
      expect(band_count(rows, "1-7d", series: "active")).to eq(1)
    end

    it "keeps an inactive thread out of the active series" do
      branch(base_age_days: 1, active: false)

      rows = stats.base_age_distribution
      expect(band_count(rows, "1-7d", series: "all")).to eq(1)
      expect(band_count(rows, "1-7d", series: "active")).to eq(0)
    end

    it "keeps a merged topic out of the active series" do
      row = branch(base_age_days: 1, active: true)
      row.topic.update_columns(merged_into_topic_id: create(:topic).id)

      expect(band_count(stats.base_age_distribution, "1-7d", series: "active")).to eq(0)
    end

    it "includes a thread one day inside the active window" do
      row = branch(base_age_days: 1)
      row.topic.update_columns(last_message_at: (PatchCi::Config::ACTIVE_THREAD_DAYS - 1).days.ago)

      expect(band_count(stats.base_age_distribution, "1-7d", series: "active")).to eq(1)
    end

    it "excludes a thread one day outside the active window" do
      row = branch(base_age_days: 1)
      row.topic.update_columns(last_message_at: (PatchCi::Config::ACTIVE_THREAD_DAYS + 1).days.ago)

      expect(band_count(stats.base_age_distribution, "1-7d", series: "active")).to eq(0)
    end

    it "excludes superseded patchsets" do
      current = branch(base_age_days: 1)
      superseded = branch(base_age_days: 1)
      superseded.update!(superseded_by: current)

      expect(band_count(stats.base_age_distribution, "1-7d")).to eq(1)
    end

    it "reads every band as unknown without a repo state" do
      branch(base_age_days: 1)

      rows = stats(state: nil).base_age_distribution
      expect(band_count(rows, "unknown")).to eq(1)
    end

    it "keeps both series when active_only is true - the toggle does not reach this chart" do
      branch(base_age_days: 1, active: false)

      rows = stats(active_only: true).base_age_distribution
      expect(band_count(rows, "1-7d", series: "all")).to eq(1)
      expect(band_count(rows, "1-7d", series: "active")).to eq(0)
    end
  end

  describe "#freshness_tiers" do
    it "counts the BaseFreshness tiers" do
      branch(base_age_days: 1)
      branch(base_age_days: 200)

      tiers = stats.freshness_tiers
      expect(tiers["recent"]).to eq(1)
      expect(tiers["stale"]).to eq(1)
      expect(tiers.keys).to eq(PatchCi::BaseFreshness::TIERS)
    end
  end

  describe "#master_check_tiers" do
    # master_at is a fixed past date, so a probe of a minute ago sits after
    # master and reads 'current'
    it "counts every tier" do
      branch(last_master_apply_at: nil)
      branch(last_master_apply_at: 1.minute.ago)

      tiers = stats.master_check_tiers

      expect(tiers.keys).to eq(PatchCi::MasterCheck::TIERS)
      expect(tiers).to eq("current" => 1, "behind" => 0, "overdue" => 0, "never" => 1)
    end

    it "honours the active-only toggle" do
      branch(last_master_apply_at: nil, active: false)

      expect(stats(active_only: true).master_check_tiers["never"]).to eq(0)
      expect(stats.master_check_tiers["never"]).to eq(1)
    end
  end

  describe "#headline" do
    it "counts patchsets and the shares" do
      fresh = branch(base_age_days: 1, ci_status: "success")
      create(:patch_ci_run, patch_branch: fresh, status: "success",
                            image_ref: "ghcr.io/x:t1", image_digest: "sha256:abc")
                            .then { |run| fresh.update!(latest_ci_run: run) }
      branch(base_age_days: 500)

      headline = stats.headline
      expect(headline[:patchsets]).to eq(2)
      expect(headline[:verdict_rate]).to be_within(0.001).of(0.5)
      expect(headline[:image_rate]).to be_within(0.001).of(0.5)
    end

    it "counts an image by digest, not by tag" do
      row = branch(base_age_days: 1, ci_status: "success")
      run = create(:patch_ci_run, patch_branch: row, status: "success",
                                  image_ref: "ghcr.io/x:t1", image_digest: nil)
      row.update!(latest_ci_run: run)

      expect(stats.headline[:image_rate]).to eq(0.0)
    end

    it "returns nil shares rather than zero with no patchsets" do
      expect(stats.headline[:verdict_rate]).to be_nil
    end

    it "computes the median base age and the recent share" do
      branch(base_age_days: 10)
      branch(base_age_days: 20)

      headline = stats.headline
      expect(headline[:median_base_age_days]).to be_within(0.001).of(15.0)
      expect(headline[:recent_rate]).to eq(1.0)
    end

    it "returns a nil recent_rate without a repo state, not a false 0%" do
      branch(base_age_days: 1)

      expect(stats(state: nil).headline[:recent_rate]).to be_nil
    end
  end

  it "does not raise from any aggregate without a repo state" do
    branch(base_age_days: 1)

    expect { stats(state: nil).all }.not_to raise_error
  end

  describe "#outcome_by_base_year" do
    def year_band(rows, year, band)
      rows.find { |row| row[:year] == year && row[:band] == band }&.dig(:count)
    end

    it "groups by the base commit's year and by outcome" do
      branch(base_age_days: 1, ci_status: "success")
      branch(base_age_days: 2000, ci_status: "tests_failed")

      rows = stats.outcome_by_base_year
      expect(year_band(rows, 2026, "success")).to eq(1)
      expect(year_band(rows, (master_at - 2000.days).year, "tests_failed")).to eq(1)
    end

    it "calls a failed apply never_applied whatever the ci_status says" do
      branch(base_age_days: 1, status: "failed", failure_stage: "apply", ci_status: "success")

      expect(year_band(stats.outcome_by_base_year, 2026, "never_applied")).to eq(1)
    end

    it "folds timeouts into their failure band" do
      branch(base_age_days: 1, ci_status: "tests_timeout")
      branch(base_age_days: 1, ci_status: "build_timeout")

      rows = stats.outcome_by_base_year
      expect(year_band(rows, 2026, "tests_failed")).to eq(1)
      expect(year_band(rows, 2026, "build_failed")).to eq(1)
    end

    it "calls a row with no ci_status no_verdict" do
      branch(base_age_days: 1, ci_status: nil)

      expect(year_band(stats.outcome_by_base_year, 2026, "no_verdict")).to eq(1)
    end

    it "reports a null base_committed_at under a nil year" do
      branch(base_age_days: nil, ci_status: "success")

      expect(year_band(stats.outcome_by_base_year, nil, "success")).to eq(1)
    end

    it "honours the active toggle - an inactive thread drops out under active_only" do
      branch(base_age_days: 1, active: false, ci_status: "success")

      expect(year_band(stats(active_only: true).outcome_by_base_year, 2026, "success")).to be_nil
    end
  end

  describe "#success_rate_by_base_year" do
    it "is success over rows carrying a verdict" do
      branch(base_age_days: 1, ci_status: "success")
      branch(base_age_days: 1, ci_status: "tests_failed")
      branch(base_age_days: 1, ci_status: nil)

      row = stats.success_rate_by_base_year.first
      expect(row[:verdicts]).to eq(2)
      expect(row[:rate]).to be_within(0.001).of(0.5)
    end

    it "omits a year with no verdicts rather than reporting a zero rate" do
      branch(base_age_days: 1, ci_status: nil)

      expect(stats.success_rate_by_base_year).to eq([])
    end
  end

  describe "#apply_failures_by_base_year" do
    it "counts each failure stage against the year's total" do
      branch(base_age_days: 1, status: "applied")
      branch(base_age_days: 1, status: "failed", failure_stage: "apply")
      branch(base_age_days: 1, status: "failed", failure_stage: "extract")

      row = stats.apply_failures_by_base_year.find { |entry| entry[:year] == 2026 }
      expect(row[:total]).to eq(3)
      expect(row[:stages]["apply"]).to eq(1)
      expect(row[:stages]["extract"]).to eq(1)
    end
  end

  describe "#build_cost_by_base_year" do
    it "medians the successful runs of branches based in that year" do
      row = branch(base_age_days: 1)
      create(:patch_ci_run, patch_branch: row, status: "success",
                            build_seconds: 100, test_seconds: 200, tests_total: 900)
      create(:patch_ci_run, patch_branch: row, status: "success",
                            build_seconds: 200, test_seconds: 400, tests_total: 1000)

      entry = stats.build_cost_by_base_year.first
      expect(entry[:year]).to eq(2026)
      expect(entry[:build_median]).to be_within(0.1).of(150)
      expect(entry[:test_median]).to be_within(0.1).of(300)
      expect(entry[:tests_median]).to be_within(0.1).of(950)
    end

    it "ignores failed runs" do
      row = branch(base_age_days: 1)
      create(:patch_ci_run, patch_branch: row, status: "tests_failed", build_seconds: 100)

      expect(stats.build_cost_by_base_year).to eq([])
    end
  end

  describe "#per_major" do
    it "reports patchsets and run medians per major" do
      row = branch(base_age_days: 1, pg_major: 20, ci_status: "success")
      create(:patch_ci_run, patch_branch: row, pg_major: 20, status: "success",
                            build_seconds: 150, test_seconds: 300, tests_total: 1000,
                            image_digest: "sha256:abc")
                            .then { |run| row.update!(latest_ci_run: run) }

      entry = stats.per_major.find { |candidate| candidate[:pg_major] == 20 }
      expect(entry[:patchsets]).to eq(1)
      expect(entry[:runs]).to eq(1)
      expect(entry[:success_rate]).to eq(1.0)
      expect(entry[:build_median]).to be_within(0.1).of(150)
      expect(entry[:era]).to eq("trixie")
      expect(entry[:era_enabled]).to be(true)
    end

    # every family in eras.yml is enabled now, so there is no real stub left to
    # point at - stub the flag instead of dropping the case, because the next
    # family added starts life as a disabled stub and still has to render
    it "keeps a major whose era image is a disabled stub, flagged" do
      allow(PatchCi::Eras).to receive(:enabled?).with(16).and_return(false)
      branch(base_age_days: 1, pg_major: 16)

      entry = stats.per_major.find { |candidate| candidate[:pg_major] == 16 }
      expect(entry[:patchsets]).to eq(1)
      expect(entry[:era]).to eq("bookworm")
      expect(entry[:era_enabled]).to be(false)
    end

    it "keeps a major with patchsets but no runs, with nil medians" do
      branch(base_age_days: 1, pg_major: 15)

      entry = stats.per_major.find { |candidate| candidate[:pg_major] == 15 }
      expect(entry[:runs]).to eq(0)
      expect(entry[:build_median]).to be_nil
      expect(entry[:success_rate]).to be_nil
    end
  end

  describe "#top_conflict_files" do
    it "counts totals and distinct branches" do
      branch(base_age_days: 1, status: "failed", failure_stage: "apply",
             conflict_files: %w[src/backend/executor/nodeHash.c])
      branch(base_age_days: 1, status: "failed", failure_stage: "apply",
             conflict_files: %w[src/backend/executor/nodeHash.c])

      row = stats.top_conflict_files.first
      expect(row[:name]).to eq("src/backend/executor/nodeHash.c")
      expect(row[:conflicts]).to eq(2)
      expect(row[:branches]).to eq(2)
    end

    it "counts a duplicate within one branch twice in the total and once in branches" do
      branch(base_age_days: 1, status: "failed", failure_stage: "apply",
             conflict_files: %w[a.c a.c])

      row = stats.top_conflict_files.first
      expect(row[:conflicts]).to eq(2)
      expect(row[:branches]).to eq(1)
    end

    it "ignores a branch that applied cleanly" do
      branch(base_age_days: 1, status: "applied", conflict_files: %w[a.c])

      expect(stats.top_conflict_files).to eq([])
    end
  end

  describe "#coverage_by_era" do
    it "splits active-discussion patchsets by whether they carry a verdict" do
      branch(base_age_days: 1, pg_major: 20, ci_status: "success", active: true)
      branch(base_age_days: 1, pg_major: 20, ci_status: nil, active: true)

      row = stats.coverage_by_era.find { |entry| entry[:era] == "trixie" }
      expect(row[:with_verdict]).to eq(1)
      expect(row[:without_verdict]).to eq(1)
    end

    it "omits an era with no patchsets" do
      branch(base_age_days: 1, pg_major: 20, active: true)

      expect(stats.coverage_by_era.map { |row| row[:era] }).to eq([ "trixie" ])
    end

    it "excludes inactive threads" do
      branch(base_age_days: 1, pg_major: 20, ci_status: "success", active: false)

      expect(stats.coverage_by_era).to eq([])
    end
  end

  describe "#wont_retry_reasons" do
    it "reads the breakdown off BranchHealth" do
      branch(base_age_days: 1, ci_status: "ci_none", ci_skip_reason: "unsupported major")

      expect(stats.wont_retry_reasons).to include("unsupported major" => 1)
    end
  end

  describe "#size_vs_outcome" do
    def sized_branch(files, **attrs)
      row = branch(base_age_days: 1, **attrs)
      files.times { |n| create(:patch_submission_file, message: row.message, path: "src/file#{n}.c") }
      row
    end

    it "buckets by submission file count" do
      sized_branch(1, ci_status: "success")
      sized_branch(3, ci_status: "success")
      sized_branch(50, ci_status: "tests_failed")

      buckets = stats.size_vs_outcome.map { |row| row[:bucket] }.uniq
      expect(buckets).to include("1", "2-5", "21-100")
    end

    it "puts a patchset with no recorded files in unknown" do
      branch(base_age_days: 1, ci_status: "success")

      expect(stats.size_vs_outcome.map { |row| row[:bucket] }).to eq([ "unknown" ])
    end

    it "carries the outcome band inside the bucket" do
      sized_branch(1, status: "failed", failure_stage: "apply")

      row = stats.size_vs_outcome.first
      expect(row[:band]).to eq("never_applied")
    end
  end

  describe "#patchsets_per_topic" do
    it "counts superseded patchsets as versions" do
      topic = create(:topic)
      first = create(:patch_branch, topic: topic)
      second = create(:patch_branch, topic: topic)
      first.update!(superseded_by: second)

      row = stats.patchsets_per_topic.find { |entry| entry[:versions] == 2 }
      expect(row[:count]).to eq(1)
    end

    it "counts an llm-linked topic as committed" do
      committed = create(:topic)
      create(:patch_branch, topic: committed)
      create(:commit_topic, topic: committed, source: "llm", confidence: 0.9)

      rows = stats.patchsets_per_topic
      expect(rows.find { |row| row[:series] == "committed" }[:count]).to eq(1)
    end

    it "splits by whether the topic was committed" do
      committed = create(:topic)
      create(:patch_branch, topic: committed)
      create(:commit_topic, topic: committed)
      create(:patch_branch, topic: create(:topic))

      rows = stats.patchsets_per_topic
      expect(rows.find { |row| row[:series] == "committed" }[:count]).to eq(1)
      expect(rows.find { |row| row[:series] == "not committed" }[:count]).to eq(1)
    end
  end
end
