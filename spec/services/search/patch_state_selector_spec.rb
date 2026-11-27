require "rails_helper"

RSpec.describe "Search ci: and apply: selectors", type: :service do
  let(:parser) { Search::QueryParser.new }
  let(:user) { create(:user) }

  def build_query(query_string)
    ast = parser.parse(query_string)
    validated = Search::QueryValidator.new(ast).validate
    Search::QueryBuilder.new(ast: validated.ast, user: user).build
  end

  def ids(query)
    build_query(query).relation.pluck(:id)
  end

  describe "ci:" do
    let!(:no_branch) { create(:topic) }
    let(:statuses) do
      Search::PatchStateQuery::CI_STATUSES.values.flatten.compact.index_with { create(:topic) }
    end

    before do
      statuses.each { |status, topic| create(:patch_branch, topic: topic, ci_status: status) }
    end

    let!(:null_status) do
      create(:topic).tap { |t| create(:patch_branch, topic: t, ci_status: nil) }
    end

    it "maps passing, failing, pending and none" do
      expect(ids("ci:passing")).to contain_exactly(statuses["success"].id)
      expect(ids("ci:failing")).to match_array(%w[build_failed build_timeout tests_failed tests_timeout].map { |s| statuses[s].id })
      expect(ids("ci:pending")).to match_array(%w[pushed_awaiting_ci queued running].map { |s| statuses[s].id })
      expect(ids("ci:none")).to match_array(
        %w[ci_none push_failed cancelled infra_error].map { |s| statuses[s].id } + [ null_status.id ]
      )
    end

    it "is case-insensitive" do
      expect(ids("ci:FAILING").size).to eq(4)
    end

    it "negation keeps topics without a branch" do
      result = ids("-ci:failing")
      expect(result).to include(no_branch.id, statuses["success"].id)
      expect(result).not_to include(statuses["tests_failed"].id)
    end

    it "ignores superseded and lineage-only branches" do
      topic = create(:topic)
      newer = create(:patch_branch, topic: topic, ci_status: "success")
      create(:patch_branch, topic: topic, ci_status: "tests_failed", superseded_by: newer)
      create(:patch_branch, topic: topic, ci_status: "build_failed", lineage_only: true)
      expect(ids("ci:failing")).not_to include(topic.id)
      expect(ids("ci:passing")).to include(topic.id)
    end

    it "reads the newest current branch" do
      topic = create(:topic)
      create(:patch_branch, topic: topic, ci_status: "tests_failed")
      create(:patch_branch, topic: topic, ci_status: "success")
      expect(ids("ci:passing")).to include(topic.id)
      expect(ids("ci:failing")).not_to include(topic.id)
    end

    it "warns and drops invalid values" do
      validated = Search::QueryValidator.new(parser.parse("ci:bogus")).validate
      expect(validated.ast).to be_nil
      expect(validated.warnings.join).to include("bogus")
    end
  end

  describe "apply:" do
    let!(:repo_state) { create(:patch_ci_repo_state) }
    let!(:no_branch) { create(:topic) }
    let!(:applies_topic) { create(:topic) }
    let!(:rebase_topic) { create(:topic) }
    let!(:never_topic) { create(:topic) }

    let!(:applies_row) do
      create(:patch_branch, topic: applies_topic, on_master: true, pushed_at: 1.day.ago,
                            ci_status: "success", base_committed_at: 1.day.ago)
    end
    let!(:rebase_row) do
      create(:patch_branch, topic: rebase_topic, on_master: true, pushed_at: 1.day.ago,
                            ci_status: "success", base_committed_at: 1.day.ago,
                            master_apply_error: "conflict")
    end
    let!(:never_row) do
      create(:patch_branch, topic: never_topic, status: "failed", failure_stage: "apply")
    end

    {
      "applies" => %i[applies_topic applies_row],
      "needs_rebase" => %i[rebase_topic rebase_row],
      "never_applied" => %i[never_topic never_row]
    }.each do |bucket, (topic_name, row_name)|
      it "apply:#{bucket} returns its topic and agrees with BranchHealth" do
        expect(ids("apply:#{bucket}")).to contain_exactly(send(topic_name).id)
        health = PatchCi::BranchHealth.new(repo_state: repo_state)
        expect(health.bucket_for(send(row_name))).to eq(bucket)
      end
    end

    it "apply:wont_retry and apply:awaiting_ci find nothing here" do
      expect(ids("apply:wont_retry")).to be_empty
      expect(ids("apply:awaiting_ci")).to be_empty
    end

    it "negation includes the applying and branchless topics" do
      result = ids("-apply:needs_rebase")
      expect(result).to include(applies_topic.id, no_branch.id)
      expect(result).not_to include(rebase_topic.id)
    end

    it "warns and drops invalid values" do
      validated = Search::QueryValidator.new(parser.parse("apply:bogus")).validate
      expect(validated.ast).to be_nil
      expect(validated.warnings.join).to include("bogus")
    end
  end
end
