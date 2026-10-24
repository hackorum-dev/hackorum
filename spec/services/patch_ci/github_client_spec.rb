require "rails_helper"

RSpec.describe PatchCi::GithubClient, :webmock do
  let(:client) { described_class.new(repo: "hackorum-dev/postgres", token: "tok") }
  let(:url) { "https://api.github.com/repos/hackorum-dev/postgres/actions/runs" }

  def run_json(id:, branch:, status:, conclusion: nil)
    {
      id: id, head_branch: branch, run_attempt: 1, status: status,
      conclusion: conclusion, head_sha: "a" * 40,
      created_at: "2026-07-26T10:00:00Z",
      run_started_at: "2026-07-26T10:01:00Z",
      updated_at: "2026-07-26T10:15:00Z"
    }
  end

  def stub_status(state, workflow_runs)
    stub_request(:get, url).with(query: hash_including("status" => state))
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { workflow_runs: workflow_runs }.to_json)
  end

  it "returns parsed runs" do
    stub_request(:get, url).with(query: hash_including({}))
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { total_count: 1,
                         workflow_runs: [ run_json(id: 7, branch: "t1_1",
                                                   status: "completed", conclusion: "success") ] }.to_json)

    runs = client.runs

    expect(runs.size).to eq(1)
    expect(runs.first.id).to eq(7)
    expect(runs.first.branch).to eq("t1_1")
    expect(runs.first.status).to eq("completed")
    expect(runs.first.conclusion).to eq("success")
  end

  it "follows pagination until a short page" do
    first = (1..100).map { |i| run_json(id: i, branch: "t#{i}_1", status: "completed", conclusion: "success") }
    stub_request(:get, url).with(query: hash_including({ "page" => "1" }))
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { workflow_runs: first }.to_json)
    stub_request(:get, url).with(query: hash_including({ "page" => "2" }))
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { workflow_runs: [ run_json(id: 101, branch: "t101_1", status: "queued") ] }.to_json)

    expect(client.runs.size).to eq(101)
  end

  it "passes status through as a query parameter" do
    stub_status("queued", [ run_json(id: 9, branch: "g", status: "queued") ])

    result = client.runs(status: "queued")

    expect(result.size).to eq(1)
    expect(result.first.status).to eq("queued")
    expect(a_request(:get, url).with(query: hash_including("status" => "queued"))).to have_been_made
  end

  it "counts only queued and in_progress as in flight" do
    stub_status("queued", [ run_json(id: 1, branch: "a", status: "queued") ])
    stub_status("in_progress", [ run_json(id: 2, branch: "b", status: "in_progress") ])
    stub_status("requested", [])
    stub_status("waiting", [])
    stub_status("pending", [])

    expect(client.in_flight_count).to eq(2)
  end

  it "also counts requested, waiting and pending as in flight" do
    stub_status("queued", [ run_json(id: 1, branch: "a", status: "queued") ])
    stub_status("in_progress", [ run_json(id: 2, branch: "b", status: "in_progress") ])
    stub_status("requested", [ run_json(id: 3, branch: "c", status: "requested") ])
    stub_status("waiting", [ run_json(id: 4, branch: "d", status: "waiting") ])
    stub_status("pending", [ run_json(id: 5, branch: "e", status: "pending") ])

    expect(client.in_flight_count).to eq(5)
  end

  it "queries per status instead of paging the full history" do
    stub_status("queued", [])
    stub_status("in_progress", [])
    stub_status("requested", [])
    stub_status("waiting", [])
    stub_status("pending", [])

    client.in_flight_count

    expect(a_request(:get, url).with(query: hash_including("status" => "queued"))).to have_been_made.once
    expect(a_request(:get, url).with(query: hash_including("status" => "in_progress"))).to have_been_made.once
    expect(a_request(:get, url).with(query: { "per_page" => "100", "page" => "1" })).not_to have_been_made
  end

  it "raises on a non-2xx response" do
    stub_request(:get, url).with(query: hash_including({}))
      .to_return(status: 403, body: "forbidden")

    expect { client.runs }.to raise_error(PatchCi::GithubClient::Error, /403/)
  end

  it "raises on a 200 with an unusable body" do
    stub_request(:get, url).with(query: hash_including({}))
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: {}.to_json)

    expect { client.runs }.to raise_error(PatchCi::GithubClient::Error, /workflow_runs/)
  end

  it "raises when no token is configured" do
    expect { described_class.new(repo: "x/y", token: nil) }
      .to raise_error(PatchCi::GithubClient::Error, /HACKORUM_GITHUB_TOKEN/)
  end

  it "drops slug sync runs" do
    stub_request(:get, url).with(query: hash_including({}))
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { workflow_runs: [ run_json(id: 1, branch: "t1_1", status: "completed"),
                                          run_json(id: 2, branch: "hackorum-slugs", status: "completed") ] }.to_json)

    expect(client.runs.map(&:id)).to eq([ 1 ])
  end

  it "does not count slug sync runs as in flight" do
    PatchCi::GithubClient::IN_FLIGHT.each { |state| stub_status(state, []) }
    stub_status("queued", [ run_json(id: 2, branch: "hackorum-slugs", status: "queued") ])

    expect(client.in_flight_count).to eq(0)
  end
end
