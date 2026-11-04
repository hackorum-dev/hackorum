require "rails_helper"

RSpec.describe Lineage::Processor::Client, :webmock do
  let(:client) { described_class.new(server: "http://srv:3000", token: "t") }
  let(:auth) { { "Authorization" => "Bearer t" } }

  it "claims and returns nil when empty" do
    stub_request(:post, "http://srv:3000/api/lineage/claims")
      .with(headers: auth.merge("Content-Type" => "application/json"), body: { worker: "w", phases: [ "trailer" ] }.to_json)
      .to_return(status: 201, body: { run_id: 7, topic_id: 3, mode: "trailer", prompt_version: "abc" }.to_json)
    claim = client.claim(worker: "w", phases: [ "trailer" ])
    expect(claim).to have_attributes(run_id: 7, topic_id: 3, mode: "trailer", prompt_version: "abc")

    stub_request(:post, "http://srv:3000/api/lineage/claims").to_return(status: 204)
    expect(client.claim(worker: "w")).to be_nil
  end

  it "downloads a bundle to a file" do
    stub_request(:get, "http://srv:3000/api/lineage/claims/7/bundle").with(headers: auth).to_return(status: 200, body: "GZ")
    Dir.mktmpdir do |dir|
      path = client.download_bundle(7, to: File.join(dir, "b.tar.gz"))
      expect(File.binread(path)).to eq("GZ")
    end
  end

  it "fails a download cleanly" do
    stub_request(:get, "http://srv:3000/api/lineage/claims/7/bundle").to_return(status: 409, body: "taken")
    Dir.mktmpdir do |dir|
      to = File.join(dir, "b.tar.gz")
      expect { client.download_bundle(7, to: to) }.to raise_error(described_class::Conflict)
      expect(Dir.children(dir)).to be_empty
    end
  end

  it "submits non-ASCII fields and files intact" do
    parsed = nil
    stub_request(:post, "http://srv:3000/api/lineage/claims/7/result").with { |req|
      env = Rack::MockRequest.env_for("/", method: "POST", input: req.body, "CONTENT_TYPE" => req.headers["Content-Type"])
      parsed = Rack::Multipart.parse_multipart(env)
      true
    }.to_return(status: 200, body: "{}")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "result.json")
      File.binwrite(path, '{"story":"Álvaro"}')
      client.submit_result(7, { exit_code: 0, stderr_tail: "Größe" }, result_path: path)
    end
    expect(parsed["stderr_tail"]).to eq("Größe")
    expect(parsed["result"][:tempfile].read.force_encoding("UTF-8")).to eq('{"story":"Álvaro"}')
  end

  it "submits a multipart result" do
    stub = stub_request(:post, "http://srv:3000/api/lineage/claims/7/result").with(headers: auth) { |req|
      req.body.include?('name="exit_code"') && req.body.include?("0\r\n") &&
        req.body.include?('name="result"; filename="result.json"') && req.body.include?('{"story":"s"}') &&
        !req.body.include?('name="failure_kind"')
    }.to_return(status: 200, body: { status: "done", error: nil }.to_json)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "result.json")
      File.write(path, '{"story":"s"}')
      reply = client.submit_result(7, { exit_code: 0, failure_kind: nil, duration_s: 1.5 }, result_path: path)
      expect(reply).to eq("status" => "done", "error" => nil)
    end
    expect(stub).to have_been_requested

    stub_request(:post, "http://srv:3000/api/lineage/claims/7/result").to_return(status: 409, body: '{"error":"done"}')
    expect { client.submit_result(7, { exit_code: 1 }) }.to raise_error(described_class::Conflict)
    stub_request(:post, "http://srv:3000/api/lineage/claims/7/result").to_return(status: 404, body: "gone")
    expect { client.submit_result(7, { exit_code: 1 }) }.to raise_error(described_class::Conflict, /404/)
    stub_request(:post, "http://srv:3000/api/lineage/claims/7/result").to_return(status: 500, body: "boom")
    expect { client.submit_result(7, { exit_code: 1 }) }.to raise_error(described_class::Error, /500/)
  end

  it "releases quietly and reads the queue" do
    stub_request(:delete, "http://srv:3000/api/lineage/claims/7").to_return(status: 409)
    expect { client.release(7) }.not_to raise_error
    stub_request(:get, "http://srv:3000/api/lineage/queue").to_return(status: 200, body: { trailer: { remaining: 1 } }.to_json)
    expect(client.queue).to eq("trailer" => { "remaining" => 1 })
  end

  it "wraps transport failures and server errors" do
    stub_request(:post, "http://srv:3000/api/lineage/claims").to_raise(Errno::ECONNREFUSED)
    expect { client.claim(worker: "w") }.to raise_error(described_class::Error, /ECONNREFUSED/)
    stub_request(:post, "http://srv:3000/api/lineage/claims").to_return(status: 500, body: "boom")
    expect { client.claim(worker: "w") }.to raise_error(described_class::Error, /500/)
    stub_request(:get, "http://srv:3000/api/lineage/queue").to_return(status: 200, body: "<html>")
    expect { client.queue }.to raise_error(described_class::Error, /ParserError/)
  end
end
