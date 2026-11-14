require "rails_helper"

RSpec.describe "API v1 guide", type: :request do
  let(:source) { Rails.root.join("docs/api/guide.md") }
  let(:guide) { source.read }
  let(:document) { OpenapiHelper.contract.document }
  let(:operations) { OpenapiHelper.contract.operations.map { |template, verb| "#{verb.upcase} #{template}" } }

  # query parameters the guide names for a request
  let(:parameters) do
    {
      "/topics" => %w[q saved_search_id team_id limit cursor],
      "/topics/{id}/messages" => %w[body limit],
      "/topics/{id}/patchsets" => %w[limit],
      "/topics/{id}/notes" => %w[message_id],
      "/messages/{id}" => %w[body],
      "/messages/lookup" => %w[rfc_message_id],
      "/branches" => %w[topic author state ci_status pg_major current],
      "/events" => %w[since types topic author list ci_runs starred participating limit],
      "/me/activities" => %w[unread],
      "/drafts" => %w[state]
    }
  end
  let(:handled_codes) do
    %w[rate_limited query_too_expensive invalid_cursor cursor_expired token_required conflict draft_limit]
  end

  def query_names(template)
    document.dig("paths", template, "get", "parameters").map do |parameter|
      parameter["name"] || document.dig(*parameter.fetch("$ref").delete_prefix("#/").split("/"), "name")
    end
  end

  [ nil, "Bearer hko_nope" ].each do |authorization|
    it "is served as markdown #{authorization ? 'with an invalid token' : 'without a token'}" do
      get "/api/v1/guide.md", headers: { "Authorization" => authorization }.compact

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/markdown")
      expect(response.headers["Content-Type"]).to eq("text/markdown; charset=utf-8")
      expect(response.headers["Cache-Control"]).to eq("max-age=3600, public")
      expect(response.headers["Content-Disposition"]).to start_with("inline")
      expect(response.body).to eq(guide)
    end
  end

  it "takes no query parameters" do
    get "/api/v1/guide.md?format=json"

    expect(response).to have_http_status(:bad_request)
    expect(JSON.parse(response.body).dig("error", "code")).to eq("invalid_parameter")
  end

  it "reads the file once outside development" do
    get "/api/v1/guide.md"
    expect(Api::V1::OpenapiController::GUIDE).not_to receive(:read)

    get "/api/v1/guide.md"

    expect(response).to have_http_status(:ok)
  end

  it "is plain ASCII markdown under 2500 words" do
    expect(guide).to be_ascii_only
    expect(guide.split.size).to be < 2500
    expect(guide).not_to match(%r{</?(a|b|br|code|div|em|h[1-6]|i|img|li|ol|p|pre|span|strong|table|td|th|tr|ul)\b[^>]*>})
  end

  it "lists exactly the operations of the OpenAPI document" do
    rows = guide.scan(/^\| (GET|POST|PATCH|DELETE) \| `([^`]+)` \| \S/).map { |verb, path| "#{verb} #{path}" }

    expect(rows).to match_array(operations)
  end

  it "names only operations the OpenAPI document has" do
    mentioned = guide.scan(/\b(GET|POST|PATCH|DELETE) (\/[\w{}\/.]*[\w}])/).map { |verb, path| "#{verb} #{path}" }.uniq

    expect(mentioned.size).to be >= 15
    expect(mentioned - operations).to eq([])
  end

  it "names only query parameters the operation takes" do
    parameters.each do |template, names|
      expect(names - query_names(template)).to eq([]), template
      names.each { |name| expect(guide).to match(/[`?&]#{name}[`=]/), "#{template} #{name}" }
    end
    guide.scan(%r{(/[\w{}/.]+)\?([^\s`)]+)}).each do |path, query|
      template = path.sub(%r{\A.*/api/v1}, "")
      expect(parameters).to have_key(template), path
      expect(query.split("&").map { |pair| pair.split("=").first } - query_names(template)).to eq([]), "#{path}?#{query}"
    end
  end

  it "names only error codes the API has, with their status" do
    pairs = guide.scan(/\b(\d{3}) `([a-z_]+)`/).uniq

    expect(pairs.map(&:last)).to include(*handled_codes)
    pairs.each { |status, code| expect(Api::ErrorCodes::STATUSES[code]).to eq(status.to_i), code }
  end

  it "has the numbers of the code" do
    size = ->(bytes) { ActiveSupport::NumberHelper.number_to_human_size(bytes) }
    limits = Rails.configuration.x.api_rate_limit
    drafts = Api::V1::DraftsController
    feed = Api::EventFeed

    expect(guide).to include(
      "#{limits.anonymous} requests a minute per IP address", "#{limits.token} per token",
      "default #{Api::CursorPaginator::DEFAULT_LIMIT}", "above #{Api::CursorPaginator::MAX_LIMIT}",
      "longer than #{Rails.configuration.x.api_statement_timeout_ms / 1000} seconds",
      "at most #{Api::TopicList::MAX_QUERY_LENGTH} characters",
      "request body: #{size.call(Api::RequestBody::MAX_BYTES)}",
      "`subject`: #{drafts::SUBJECT_LIMIT} characters", "text: #{size.call(drafts::BODY_BYTES)}",
      "`quote`: #{size.call(drafts::QUOTE_BYTES)}",
      "attachments of one draft: #{size.call(OutgoingDraft::MAX_ATTACHMENT_BYTES)}",
      "#{Drafts::TokenLimits::ACTIVE_DRAFTS} unsent drafts",
      "#{size.call(Drafts::TokenLimits::ATTACHMENT_BYTES)} of attachments",
      "#{Api::V1::BaseController::LOCK_TIMEOUT_MS / 1000} seconds for a draft",
      "keeps #{feed::RETENTION.in_days.to_i} days", "last #{feed::HOLD_BACK.to_i} seconds",
      "`since=#{feed::DEFAULT_SINCE}`",
      "By default the feed leaves out CI runs that only repeat the previous verdict of the same patchset",
      "`ci_runs=#{(feed::CI_RUNS - [ feed::DEFAULT_CI_RUNS ]).sole}` gives every run",
      "A run is reported again if its verdict changes"
    )
  end

  it "says that the API cannot send, and points to the other documents" do
    expect(guide).to include("The API cannot send", "refuses to send a draft that changed after the owner confirmed it",
                             "`html_url`", "/api/v1/openapi.yaml", "/api/docs")
    expect(guide).not_to match(%r{/send\b|send_now})
    expect(document.dig("info", "description")).to include("(/api/v1/guide.md)", "(/api/docs)")
  end
end
