require "rails_helper"

RSpec.describe "Admin::ClassificationRuns", type: :request do
  let(:group) { create(:feature_group, name: "FOR PORTION OF") }
  let(:linked) { create(:topic, title: "Earlier temporal thread") }
  let(:result) do
    { "kind" => "feature", "size" => "major", "enhancement" => false, "not_a_bug" => false,
      "group" => { "id" => group.id, "new_name" => nil, "new_summary" => nil }, "join_linked" => [ linked.id ],
      "feature_name" => "UPDATE/DELETE FOR PORTION OF", "evidence" => [ "[001] adds FOR PORTION OF" ], "confidence" => "high" }
  end

  before { create(:release_tag, name: Classify::Scope::WINDOW_TAG, released_at: 3.years.ago) }

  it "redirects non-admins" do
    sign_in_as(create(:user, admin: false))
    get admin_classification_runs_path
    expect(response).to redirect_to(root_path)
  end

  describe "as admin" do
    before { sign_in_as(create(:user, admin: true)) }

    let!(:done) do
      create(:classification_run, topic: create(:topic, title: "Temporal update"), phase: "backfill", kind: "feature", size: "major",
                                  enhancement: false, feature_group: group, model: "gpt-6.2-sol", effort: "medium",
                                  input_tokens: 4321, cached_input_tokens: 100, output_tokens: 50, duration_s: 12.0, result:)
    end
    let!(:failed) do
      create(:classification_run, topic: create(:topic, title: "Broken run"), status: "failed", failure_kind: "schema",
                                  error: "schema: missing kind", input_tokens: 10)
    end

    it "lists runs with queue and status counts" do
      get admin_classification_runs_path(sort: "tokens")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Temporal update", "Broken run", "4321", "FOR PORTION OF", "major", "schema")
      expect(response.body).to include("backfill:", "remaining", "done: 1", "failed: 1")
      expect(response.body.index("Temporal update")).to be < response.body.index("Broken run")
    end

    it "filters by status" do
      get admin_classification_runs_path(status: "failed")
      expect(response.body).to include("Broken run")
      expect(response.body).not_to include("Temporal update")
    end

    it "shows the answer of a run" do
      get admin_classification_run_path(done)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("UPDATE/DELETE FOR PORTION OF", "[001] adds FOR PORTION OF", "Earlier temporal thread", "gpt-6.2-sol / medium")
      expect(response.body).not_to include("Requeue")
    end

    it "shows the error and requeues a failed run" do
      get admin_classification_run_path(failed)
      expect(response.body).to include("schema: missing kind", "Requeue")
      post requeue_admin_classification_run_path(failed)
      expect(ClassificationRun.exists?(failed.id)).to be(false)
      expect(flash[:notice]).to be_present
    end

    it "does not requeue a done run" do
      post requeue_admin_classification_run_path(done)
      expect(ClassificationRun.exists?(done.id)).to be(true)
      expect(flash[:alert]).to be_present
    end
  end
end
