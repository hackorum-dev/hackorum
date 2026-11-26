require "rails_helper"

RSpec.describe "Classify API", type: :request do
  let(:headers) { { "Authorization" => "Bearer sekrit" } }
  let(:json_headers) { headers.merge("CONTENT_TYPE" => "application/json") }
  let(:hackers) { create(:mailing_list, identifier: "pgsql-hackers") }
  let(:valid_json) do
    { kind: "feature", size: "minor", enhancement: false, not_a_bug: false, join_linked: [], group: { id: nil, new_name: nil, new_summary: nil },
      feature_name: "x", evidence: [ "e" ], confidence: "high" }
  end

  def upload(data)
    file = Tempfile.new([ "result", ".json" ])
    file.write(JSON.dump(data))
    file.close
    Rack::Test::UploadedFile.new(file.path, "application/json")
  end

  def claim!
    post api_classify_claims_path, params: { worker: "box" }.to_json, headers: json_headers
    ClassificationRun.find(JSON.parse(response.body)["run_id"])
  end

  around do |ex|
    Dir.mktmpdir { |dir| with_env("LINEAGE_API_TOKEN" => "sekrit", "CLASSIFY_BUNDLES_ROOT" => dir) { ex.run } }
  end

  before do
    Classify::Setup.call!
    create(:release_tag, name: "REL_16_BETA1", released_at: Time.zone.parse("2024-05-21"))
  end

  let!(:topic) do
    create(:topic, created_at: 3.days.ago).tap do |t|
      create(:message, topic: t, created_at: 3.days.ago)
      create(:topic_mailing_list, topic: t, mailing_list: hackers)
    end
  end

  it "requires the token" do
    get api_classify_queue_path
    expect(response).to have_http_status(:unauthorized)
    get api_classify_queue_path, headers: headers
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to include("new", "recheck", "backfill")
  end

  it "claims, serves a bundle with prompt.md and ingests a result" do
    post api_classify_claims_path, params: { worker: "box" }.to_json, headers: json_headers
    expect(response).to have_http_status(:created)
    claim = JSON.parse(response.body)
    expect(claim).to include("topic_id" => topic.id, "mode" => "new", "prompt_version" => Classify::BundleWriter.prompt_version)

    run = ClassificationRun.find(claim["run_id"])
    get bundle_api_classify_claim_path(run), headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/gzip")
    tar = File.join(ENV["CLASSIFY_BUNDLES_ROOT"], "b.tar.gz")
    File.binwrite(tar, response.body)
    expect(`tar -tzf #{tar}`).to include("prompt.md")

    post result_api_classify_claim_path(run), params: { exit_code: 0, model: "m", result: upload(valid_json) }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(run.reload).to have_attributes(status: "done", model: "m")
    expect(Classify::BotNote.new(topic).note.body).to include("#feature")
  end

  it "answers 503 before setup ran" do
    GlobalTag.find_by!(name: "bug").retire!
    post api_classify_claims_path, params: { worker: "box" }.to_json, headers: json_headers
    expect(response).to have_http_status(:service_unavailable)
    expect(JSON.parse(response.body)["error"]).to include("Classify::Setup")
  end

  it "reports the failure kind of a result" do
    run = claim!
    allow_any_instance_of(Classify::BotNote).to receive(:write!).and_raise("x")
    post result_api_classify_claim_path(run), params: { exit_code: 0, result: upload(valid_json) }, headers: headers
    expect(JSON.parse(response.body)).to include("status" => "failed", "failure_kind" => "ingest")
  end

  it "answers 409 when the bundle build breaks" do
    run = claim!
    allow_any_instance_of(Classify::BundleWriter).to receive(:write).and_raise("boom")
    get bundle_api_classify_claim_path(run), headers: headers
    expect(response).to have_http_status(:conflict)
    expect(run.reload.failure_kind).to eq("bundle")
  end

  it "answers 204 on an empty queue" do
    claim!
    post api_classify_claims_path, params: { worker: "box" }.to_json, headers: json_headers
    expect(response).to have_http_status(:no_content)
  end

  it "records codex failures and timeouts" do
    run = claim!
    post result_api_classify_claim_path(run), params: { exit_code: 1, error_message: "boom" }, headers: headers
    expect(run.reload.status).to eq("failed")

    other = create(:classification_run, topic: create(:topic), status: "claimed", claimed_at: Time.current, finished_at: nil)
    post result_api_classify_claim_path(other), params: { exit_code: 0, timed_out: "true" }, headers: headers
    expect(other.reload.status).to eq("timeout")
  end

  it "refuses results for merged topics" do
    run = claim!
    run.topic.update!(merged_into_topic: create(:topic))
    post result_api_classify_claim_path(run), params: { exit_code: 0, result: upload(valid_json) }, headers: headers
    expect(response).to have_http_status(:conflict)
    expect(ClassificationRun.exists?(run.id)).to be(false)
  end

  it "releases a claim" do
    run = claim!
    delete api_classify_claim_path(run), headers: headers
    expect(response).to have_http_status(:no_content)
    expect(ClassificationRun.exists?(run.id)).to be(false)
  end
end
