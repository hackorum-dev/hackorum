require "rails_helper"

RSpec.describe "API v1 statement timeout", type: :request do
  let(:connection) { ActiveRecord::Base.lease_connection }

  around do |example|
    settings = Rails.configuration.x
    saved = settings.api_statement_timeout_ms
    settings.api_statement_timeout_ms = 50
    example.run
  ensure
    settings.api_statement_timeout_ms = saved
  end

  def error
    JSON.parse(response.body).fetch("error")
  end

  def session_timeout
    connection.select_value("SHOW statement_timeout")
  end

  def slow_topic_list(seen = {})
    allow_any_instance_of(Api::TopicList).to receive(:relation) do
      seen[:timeout] = session_timeout
      seen[:pid] = connection.select_value("SELECT pg_backend_pid()")
      connection.execute("SELECT pg_sleep(0.3)")
      Topic.none
    end
    seen
  end

  def expect_too_expensive
    expect(response).to have_http_status(:bad_request)
    expect(response.media_type).to eq("application/json")
    expect(error["code"]).to eq("query_too_expensive")
    expect(error["message"]).to match(/narrow/i)
  end

  it "answers a statement over the limit with query_too_expensive" do
    slow_topic_list

    get "/api/v1/topics"

    expect_too_expensive
    expect(response.headers["RateLimit-Limit"]).to be_present
  end

  it "keeps the token touch of a request that fails" do
    token, secret = ApiToken.issue!(user: create(:user), name: "laptop")
    slow_topic_list

    get "/api/v1/topics", headers: { "Authorization" => "Bearer #{secret}" }

    expect_too_expensive
    expect(token.reload.last_used_at).to be_present
  end

  it "sets the timeout first on every action that reads the database" do
    secret = ApiToken.issue!(user: create(:user), name: "laptop").last
    paths = %w[/me /mailing_lists /people/nobody@example.org /topics /topics/1 /topics/no-such-slug /topics/1/messages
               /messages/lookup?rfc_message_id=x /messages/1 /attachments/1 /attachments/1/content]

    paths.each do |path|
      queries = captured_queries { get "/api/v1#{path}", headers: { "Authorization" => "Bearer #{secret}" } }
      in_action = queries.drop_while { |sql| sql.include?("api_tokens") }

      expect(response.status).to be_in([ 200, 404 ]), "#{path} gave #{response.status}"
      expect(in_action.first).to eq("SET LOCAL statement_timeout = 50"), "#{path} ran #{in_action.first.inspect} first"
      expect(queries.grep(/statement_timeout/).size).to eq(1), path
    end
  end

  it "times out on a person and on one topic" do
    slow = lambda do |*|
      connection.execute("SELECT pg_sleep(0.3)")
      nil
    end
    allow(Person).to receive(:find_by_email, &slow)
    get "/api/v1/people/alice@example.org"
    expect_too_expensive

    topic = create(:topic, creator_alias: create(:alias, :with_sent_messages), last_message_at: 1.day.ago)
    allow_any_instance_of(Api::V1::TopicSerializer).to receive(:full, &slow)
    get "/api/v1/topics/#{topic.id}"
    expect_too_expensive
  end

  it "opens no transaction for the document, the guide and unknown paths" do
    %w[/openapi.json /openapi.yaml /guide.md /nope].each do |path|
      queries = captured_queries { get "/api/v1#{path}" }

      expect(queries).to be_empty, "#{path} ran #{queries.inspect}"
    end
  end

  it "does not stop a request that renders in a handler or redirects" do
    creator = create(:alias, :with_sent_messages)
    target = create(:topic, creator_alias: creator, last_message_at: 1.day.ago)
    source = create(:topic, creator_alias: creator, last_message_at: 2.days.ago, merged_into_topic_id: target.id)

    get "/api/v1/topics/#{source.id}"
    expect(response).to have_http_status(:moved_permanently)

    get "/api/v1/topics", params: { limit: "x" }
    expect(response).to have_http_status(:bad_request)
    expect(error["code"]).to eq("invalid_limit")

    get "/api/v1/topics/#{target.id}"
    expect(response).to have_http_status(:ok)
  end

  describe "resource errors of the database" do
    def failing_with(cause)
      allow_any_instance_of(Api::TopicList).to receive(:relation) do
        begin
          raise cause, "out of shared memory"
        rescue cause
          raise ActiveRecord::StatementInvalid, "PG: out of shared memory"
        end
      end
    end

    it "are query_too_expensive" do
      [ PG::OutOfMemory, PG::DiskFull, PG::ConfigurationLimitExceeded, PG::StatementTooComplex ].each do |cause|
        failing_with(cause)

        get "/api/v1/topics"

        expect_too_expensive
      end
    end

    it "leaves any other statement error a 500" do
      config = Rails.application.env_config
      saved = config.slice("action_dispatch.show_exceptions", "action_dispatch.show_detailed_exceptions")
      config.merge!("action_dispatch.show_exceptions" => :all, "action_dispatch.show_detailed_exceptions" => false)
      failing_with(PG::UndefinedTable)

      get "/api/v1/topics"

      expect(response).to have_http_status(:internal_server_error)
      expect(error["code"]).to eq("internal_error")
    ensure
      config.merge!(saved)
    end
  end

  describe "on a pooled connection" do
    self.use_transactional_tests = false

    it "leaves the session timeout as it was, after a failure and after a success" do
      default = session_timeout
      pid = connection.select_value("SELECT pg_backend_pid()")
      seen = slow_topic_list

      get "/api/v1/topics"
      expect_too_expensive
      expect(seen).to eq(timeout: "50ms", pid: pid)
      expect(session_timeout).to eq(default)

      RSpec::Mocks.space.reset_all
      queries = captured_queries { get "/api/v1/topics" }
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["data"]).to eq([])
      expect(queries.first).to eq("SET LOCAL statement_timeout = 50")
      expect(connection.select_value("SELECT pg_backend_pid()")).to eq(pid)
      expect(session_timeout).to eq(default)
    end
  end

  describe "the setting" do
    let(:initializer) { Rails.root.join("config/initializers/api_statement_timeout.rb").to_s }

    it "defaults to 5000 and is read from the environment" do
      with_env("API_STATEMENT_TIMEOUT_MS" => nil) { load initializer }
      expect(Rails.configuration.x.api_statement_timeout_ms).to eq(5000)

      with_env("API_STATEMENT_TIMEOUT_MS" => "") { load initializer }
      expect(Rails.configuration.x.api_statement_timeout_ms).to eq(5000)

      with_env("API_STATEMENT_TIMEOUT_MS" => "250") { load initializer }
      expect(Rails.configuration.x.api_statement_timeout_ms).to eq(250)
    end

    it "rejects a value that is not a whole, non-negative number" do
      [ "abc", "5s", "1.5", "-1" ].each do |bad|
        with_env("API_STATEMENT_TIMEOUT_MS" => bad) do
          expect { load initializer }.to raise_error(ArgumentError), bad
        end
      end
    end
  end
end
