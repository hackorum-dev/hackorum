require "rails_helper"

RSpec.describe "Lineage API", type: :request do
  let(:patch) { "diff --git a/src/backend/x.c b/src/backend/x.c\n--- a/src/backend/x.c\n+++ b/src/backend/x.c\n@@ -1,1 +1,2 @@\n a\n+b\n" }

  def thread(first_at, linked: false)
    topic = create(:topic)
    2.times do |i|
      m = create(:message, topic: topic, created_at: first_at + i.days, is_patch_submission: true)
      create(:attachment, message: m, file_name: "0001-x.patch", body: Base64.encode64(patch))
    end
    create(:commit_topic, topic: topic, commit: create(:commit), source: "trailer") if linked
    topic
  end

  let(:headers) { { "Authorization" => "Bearer sekrit" } }
  let(:json_headers) { headers.merge("CONTENT_TYPE" => "application/json") }

  around do |ex|
    Dir.mktmpdir { |dir| with_env("LINEAGE_API_TOKEN" => "sekrit", "LINEAGE_BUNDLES_ROOT" => dir) { ex.run } }
  end

  it "is absent without a configured token and closed without the right one" do
    with_env("LINEAGE_API_TOKEN" => nil) do
      get api_lineage_queue_path, headers: headers
      expect(response).to have_http_status(:not_found)
    end
    get api_lineage_queue_path
    expect(response).to have_http_status(:unauthorized)
    get api_lineage_queue_path, headers: { "Authorization" => "Bearer nope" }
    expect(response).to have_http_status(:unauthorized)
    get api_lineage_queue_path, headers: headers
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to include("trailer", "full", "lineage")
  end

  it "claims, serves the bundle, takes the result" do
    topic = thread(Time.zone.parse("2020-01-01"))

    post api_lineage_claims_path, params: { worker: "box" }.to_json, headers: json_headers
    expect(response).to have_http_status(:created)
    claim = JSON.parse(response.body)
    expect(claim).to include("topic_id" => topic.id, "mode" => "lineage")
    run = PatchsetRun.find(claim["run_id"])
    expect(run.worker).to eq("box")

    get bundle_api_lineage_claim_path(run), headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/gzip")
    tar = File.join(ENV["LINEAGE_BUNDLES_ROOT"], "b.tar.gz")
    File.binwrite(tar, response.body)
    expect(`tar -tzf #{tar}`).to include("index.json")

    ids = run.bundle_index["patchsets"].map { |p| p["message_id"] }
    result = File.join(ENV["LINEAGE_BUNDLES_ROOT"], "result.json")
    File.write(result, JSON.dump(
      "lineage" => [ { "message_id" => ids[0], "parent_message_id" => nil, "step_kind" => "new_series", "confidence" => 1, "reason" => "r" },
                     { "message_id" => ids[1], "parent_message_id" => ids[0], "step_kind" => "resend", "confidence" => 1, "reason" => "r" } ],
      "verdicts" => [], "extra_commits" => [], "story" => "s"))
    post result_api_lineage_claim_path(run), headers: headers,
         params: { exit_code: 0, timed_out: "false", input_tokens: 5, cached_input_tokens: 1, output_tokens: 2,
                   duration_s: 12.5, model: "m", effort: "high", job_dir: "/jobs/x",
                   result: Rack::Test::UploadedFile.new(result, "application/json") }
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to eq("status" => "done", "error" => nil)
    expect(run.reload).to have_attributes(status: "done", duration_s: 12.5, input_tokens: 5, job_dir: "/jobs/x")

    get bundle_api_lineage_claim_path(run), headers: headers
    expect(response).to have_http_status(:conflict)
    post result_api_lineage_claim_path(run), headers: headers, params: { exit_code: 1 }
    expect(response).to have_http_status(:conflict)
    delete api_lineage_claim_path(run), headers: headers
    expect(response).to have_http_status(:conflict)

    post api_lineage_claims_path, params: { worker: "box" }.to_json, headers: json_headers
    expect(response).to have_http_status(:no_content)
  end

  it "records a timeout from the form value and releases claims" do
    thread(Time.zone.parse("2020-01-01"))
    post api_lineage_claims_path, params: { worker: "box", phases: [ "lineage" ] }.to_json, headers: json_headers
    run = PatchsetRun.find(JSON.parse(response.body)["run_id"])

    delete api_lineage_claim_path(run), headers: headers
    expect(response).to have_http_status(:no_content)
    expect(PatchsetRun.exists?(run.id)).to be(false)

    post api_lineage_claims_path, params: { worker: "box" }.to_json, headers: json_headers
    run = PatchsetRun.find(JSON.parse(response.body)["run_id"])
    post result_api_lineage_claim_path(run), headers: headers,
         params: { exit_code: 143, timed_out: "true", failure_kind: "timeout" }
    expect(JSON.parse(response.body)["status"]).to eq("timeout")
  end

  it "fails a run that exits 0 without uploading a result" do
    thread(Time.zone.parse("2020-01-01"))
    post api_lineage_claims_path, params: { worker: "box" }.to_json, headers: json_headers
    run = PatchsetRun.find(JSON.parse(response.body)["run_id"])
    post result_api_lineage_claim_path(run), headers: headers, params: { exit_code: 0 }
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to include("status" => "failed")
    expect(run.reload.failure_kind).to eq("upload")
  end

  it "fails a run whose result is not a file" do
    thread(Time.zone.parse("2020-01-01"))
    post api_lineage_claims_path, params: { worker: "box" }.to_json, headers: json_headers
    run = PatchsetRun.find(JSON.parse(response.body)["run_id"])
    post result_api_lineage_claim_path(run), headers: headers, params: { exit_code: 0, result: "not a file" }
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to include("status" => "failed")
    expect(run.reload.failure_kind).to eq("upload")
  end

  it "validates claim params" do
    post api_lineage_claims_path, params: { worker: "box", phases: [ "bogus" ] }.to_json, headers: json_headers
    expect(response).to have_http_status(:unprocessable_content)
    post api_lineage_claims_path, params: {}.to_json, headers: json_headers
    expect(response).to have_http_status(:bad_request)
    get bundle_api_lineage_claim_path(0), headers: headers
    expect(response).to have_http_status(:not_found)
  end
end
