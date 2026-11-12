require "rails_helper"

RSpec.configure do |config|
  config.after(:suite) do
    next unless OpenapiHelper.full_run?(config) && !RSpec.world.wants_to_quit

    missing = OpenapiHelper.contract.unexercised
    next if missing.empty?

    raise "openapi.yaml operations without a validated 2xx response in spec/requests/api/v1:\n" +
          missing.map { |template, verb| "  #{verb.upcase} #{template}" }.join("\n")
  end
end

RSpec.describe "API v1 OpenAPI document", type: :request do
  let(:contract) { OpenapiHelper.contract }

  it "is a valid OpenAPI document" do
    errors = contract.schemer.validate.map { |e| e["error"] }
    expect(errors).to eq([])
  end

  it "has no mapping key twice" do
    expect(OpenapiHelper.duplicate_keys(Psych.parse_file(OpenapiHelper::SOURCE.to_s))).to eq([])
  end

  it "has only quoted statuses and default as response keys" do
    expect(contract.lint_response_keys).to eq([])
  end

  it "closes every object schema and requires only known properties" do
    expect(contract.lint_schemas).to eq([])
  end

  it "has no dangling $ref" do
    expect(contract.lint_refs).to eq([])
  end

  it "uses only defined security schemes" do
    expect(contract.lint_security).to eq([])
  end

  it "documents a required JSON body with a closed schema where the verb takes one" do
    expect(contract.lint_request_bodies).to eq([])
  end

  describe "operations" do
    let(:operations) do
      contract.operations.to_h { |template, verb| [ [ template, verb ], contract.document.dig("paths", template, verb) ] }
    end
    let(:public_templates) { %w[/openapi.json /openapi.yaml /guide.md] }

    def query_names(template, operation)
      shared = contract.document.dig("paths", template, "parameters") || []
      (shared + (operation["parameters"] || [])).filter_map do |parameter|
        parameter = contract.document.dig(*parameter["$ref"].delete_prefix("#/").split("/")) if parameter.key?("$ref")
        parameter["name"] if parameter["in"] == "query"
      end
    end

    it "gives every operation a tag the document describes, and describes no other" do
      defined = contract.document["tags"].map { |tag| tag["name"] }

      expect(contract.document["tags"].map { |tag| tag["description"] }).to all(be_present)
      operations.each do |(template, verb), operation|
        expect(operation["tags"]).to be_present, "#{verb} #{template}"
        expect(operation["tags"] - defined).to eq([]), "#{verb} #{template}"
      end
      expect(defined - operations.values.flat_map { |operation| operation["tags"] }).to eq([])
    end

    it "declares the 401 on every operation that reads the token" do
      unauthorized = { "$ref" => "#/components/responses/Unauthorized" }

      operations.each do |(template, verb), operation|
        declared = operation.dig("responses", "401")
        if public_templates.include?(template)
          expect(declared).to be_nil, "#{verb} #{template}"
        else
          expect(declared).to eq(unauthorized), "#{verb} #{template}"
        end
      end
      skipping = OpenapiHelper.operation_actions.select do |_, (controller, action)|
        controller._process_action_callbacks.none? do |callback|
          callback.filter == :authenticate_token && callback.kind == :before
        end
      end
      expect(skipping.keys.map(&:first)).to match_array(public_templates)
    end

    it "documents the query parameters each action takes, and no other" do
      actions = OpenapiHelper.operation_actions

      expect(actions.keys).to match_array(operations.keys)
      operations.each do |(template, verb), operation|
        controller, action = actions.fetch([ template, verb ])
        declared = controller.allowed_query_params.fetch(action, [])
        expect(declared.sort).to eq(query_names(template, operation).sort), "#{verb} #{template} (#{controller}##{action})"
      end
      actions.values.group_by(&:first).each do |controller, pairs|
        expect(controller.allowed_query_params.keys - pairs.map(&:last)).to eq([]), controller.name
      end
    end

    it "documents the body fields each action takes, and no other" do
      actions = OpenapiHelper.operation_actions
      types = { string: "string", id: "integer", timestamp: "string" }

      with_body = operations.keys.select do |template, verb|
        controller, action = actions.fetch([ template, verb ])
        declared = controller.request_bodies[action]
        schema = contract.request_body_schema(template, verb)
        expect(schema.nil?).to eq(declared.nil?), "#{verb} #{template} (#{controller}##{action})"
        next false unless declared

        expect(schema["properties"].keys.sort).to eq(declared.names.sort), "#{verb} #{template}"
        expect(Array(schema["required"]).sort).to eq(declared.required.sort), "#{verb} #{template}"
        declared.fields.each_value do |field|
          property = schema.dig("properties", field.name)
          where = "#{verb} #{template} #{field.name}"
          expect(property["type"]).to eq(types.fetch(field.type)), where
          expect(property["format"]).to eq(field.type == :timestamp ? "date-time" : nil), where
          expect(property["maxLength"]).to eq(field.max_length), where
          expect(property["minLength"]).to eq(field.blank ? nil : 1), where
          expect(property["description"]).to include(ActiveSupport::NumberHelper.number_to_human_size(field.max_bytes)), where if field.max_bytes
        end
        true
      end
      expect(with_body.map(&:last)).to include("post", "patch")
      actions.values.group_by(&:first).each do |controller, pairs|
        expect(controller.request_bodies.keys - pairs.map(&:last)).to eq([]), controller.name
      end
    end

    it "bounds the parameters as the code does" do
      parameters = ->(template) { contract.document.dig("paths", template, "get", "parameters").index_by { |row| row["name"] } }
      topics = parameters.("/topics")
      branches = parameters.("/branches")
      shared = contract.document.dig("components", "parameters")

      expect(topics.dig("q", "schema", "maxLength")).to eq(Api::TopicList::MAX_QUERY_LENGTH)
      expect(topics.dig("list", "schema", "maxLength")).to eq(Api::V1::TopicsController::LIST_LIMIT)
      expect(topics.dig("author", "schema", "maxLength")).to eq(Api::V1::BaseController::AUTHOR_LIMIT)
      expect(branches.dig("author", "schema", "maxLength")).to eq(Api::V1::BaseController::AUTHOR_LIMIT)
      expect(parameters.("/messages/lookup").dig("rfc_message_id", "schema", "maxLength"))
        .to eq(Api::V1::MessagesController::RFC_MESSAGE_ID_LIMIT)
      expect(shared.dig("cursor", "schema", "maxLength")).to eq(Api::CursorPaginator::MAX_CURSOR)
      events = parameters.("/events")
      expect(events.dig("author", "schema", "maxLength")).to eq(Api::V1::BaseController::AUTHOR_LIMIT)
      expect(events.dig("list", "schema", "maxLength")).to eq(Api::V1::TopicsController::LIST_LIMIT)
      expect(events.dig("topic", "schema")).to eq(branches.dig("topic", "schema"))
      expect(Api::EventFeed::TOPIC_ID).to eq(PatchCi::BranchQuery::TOPIC_ID)
      %w[starred participating].each do |name|
        expect(events.dig(name, "schema", "enum")).to eq(Api::V1::EventsController::FLAGS.keys.compact)
      end
      { "topic" => PatchCi::BranchQuery::TOPIC_ID, "pg_major" => PatchCi::BranchQuery::PG_MAJOR }.each do |name, pattern|
        low, high = branches.dig(name, "schema").values_at("minimum", "maximum")
        expect(low).to eq(0)
        expect(high.to_s).to match(/\A9+\z/)
        expect(high.to_s).to match(pattern)
        expect((high + 1).to_s).not_to match(pattern)
      end
    end
  end

  describe "error codes" do
    let(:sources) do
      Dir[Rails.root.join("app/controllers/api/v1/**/*.rb"), Rails.root.join("app/controllers/concerns/api/v1/**/*.rb")] +
        [ Rails.root.join("config/initializers/rack_attack.rb").to_s ]
    end
    let(:emitted) do
      code = sources.flat_map { |file| File.read(file).scan(/render_error\(?\s*:(\w+)|code: "(\w+)"/).flatten.compact }
      (code + ApiExceptionsApp::CODES.values).uniq
    end

    it "are all in the one list, with the status they are sent with" do
      expect(emitted).to match_array(Api::ErrorCodes::STATUSES.keys)
      ApiExceptionsApp::CODES.each { |status, code| expect(Api::ErrorCodes::STATUSES[code]).to eq(status), code }
      expect(Api::ErrorCodes::STATUSES["rate_limited"]).to eq(429)
    end

    it "are all in the description, with their status" do
      rows = contract.document.dig("info", "description").scan(/^\| `(\w+)` \| (\d{3}) \|/)

      expect(rows.to_h.transform_values(&:to_i)).to eq(Api::ErrorCodes::STATUSES)
      expect(rows.size).to eq(Api::ErrorCodes::STATUSES.size)
    end
  end

  %w[Topic PersonTopic].each do |name|
    it "repeats TopicBrief in #{name} word for word" do
      brief, full = contract.document.dig("components", "schemas").values_at("TopicBrief", name)

      expect(full["properties"].slice(*brief["properties"].keys)).to eq(brief["properties"])
      expect(full["required"].first(brief["required"].size)).to eq(brief["required"])
      expect(full["additionalProperties"]).to be(false)
      expect(brief["additionalProperties"]).to be(false)
    end
  end

  it "repeats DraftBrief in Draft word for word, with the text and the recipients added" do
    brief, full = contract.document.dig("components", "schemas").values_at("DraftBrief", "Draft")
    added = %w[body recipients recipients_error]

    expect(full["properties"].except(*added)).to eq(brief["properties"])
    expect(full["properties"].keys - brief["properties"].keys).to eq(added)
    expect(full["required"] - added).to eq(brief["required"])
    expect(full["required"]).to match_array(full["properties"].keys)
  end

  describe "enums" do
    let(:schemas) { contract.document.dig("components", "schemas") }

    it "has the states of a draft, each one described" do
      states = Api::V1::DraftsController::STATES
      filter = contract.document.dig("paths", "/drafts", "get", "parameters").find { |parameter| parameter["name"] == "state" }

      expect(schemas.dig("DraftState", "enum")).to match_array(states)
      states.each { |state| expect(schemas.dig("DraftState", "description")).to include("`#{state}`") }
      expect(filter["schema"]).to eq("$ref" => "#/components/schemas/DraftState")
      %w[Draft DraftBrief].each do |name|
        expect(schemas.dig(name, "properties", "state")).to eq("$ref" => "#/components/schemas/DraftState")
      end
      expect(OutgoingDraft::STATUSES - states).to eq([ OutgoingDraft::STATUS_IDLE ])
    end

    it "has the CI statuses of the runs, each one described" do
      expect(schemas.dig("CiStatus", "enum")).to match_array(PatchCiRun::STATUSES)
      PatchCiRun::STATUSES.each { |status| expect(schemas.dig("CiStatus", "description")).to include("`#{status}`") }
    end

    it "uses CiStatus wherever a CI status is given" do
      ref = { "$ref" => "#/components/schemas/CiStatus" }
      nullable = { "oneOf" => [ ref, { "type" => "null" } ] }

      expect(schemas.dig("CiRun", "properties", "status")).to eq("$ref" => "#/components/schemas/CiRunStatus")
      %w[BranchBrief TopicCi Branch].each do |name|
        expect(schemas.dig(name, "properties", "ci_status").slice("oneOf")).to eq(nullable), name
      end
      parameters = contract.document.dig("paths", "/branches", "get", "parameters")
      filter = parameters.find { |parameter| parameter["name"] == "ci_status" }
      expect(filter.dig("schema", "enum")).to match_array(PatchCi::BranchQuery::RESULT_VALUES)
    end

    it "has the statuses a run can be stored with, each one a CI status" do
      stored = PatchCi::Ingestor::LIFECYCLE.values + %w[running] + PatchCiRun::TERMINAL_STATUSES

      expect(schemas.dig("CiRunStatus", "enum")).to match_array(stored.uniq)
      expect(schemas.dig("CiRunStatus", "enum") - schemas.dig("CiStatus", "enum")).to eq([])
    end

    it "has the branch states of the health buckets" do
      expect(schemas.dig("BranchState", "enum")).to match_array(PatchCi::BranchHealth::BUCKETS)
      PatchCi::BranchHealth::BUCKETS.each do |bucket|
        expect(schemas.dig("BranchState", "description")).to include("`#{bucket}`")
      end
    end

    it "has the states of a message" do
      %w[Message MessageDetail].each do |name|
        expect(schemas.dig(name, "properties", "state", "enum")).to match_array([ Message::STATE_SENT, Message::STATE_PENDING ])
      end
      expect(Message.constants.grep(/\ASTATE_/).size).to eq(2)
    end

    it "has the statuses of a branch" do
      %w[Branch BranchBrief].each do |name|
        expect(schemas.dig(name, "properties", "status", "enum")).to match_array(PatchBranch::STATUSES), name
      end
    end

    it "has the values the controllers take for body, sort, state and current" do
      body = contract.document.dig("components", "parameters", "body", "schema")
      branches, topics = %w[/branches /topics].map do |template|
        contract.document.dig("paths", template, "get", "parameters").index_by { |parameter| parameter["name"] }
      end

      expect(body["enum"]).to match_array(Api::V1::MessageSerializer::BODIES)
      expect(body["default"]).to eq(Api::V1::MessageSerializer::DEFAULT_BODY)
      expect(topics.dig("sort", "schema", "enum")).to match_array(Api::TopicList::SORTS.keys)
      expect(topics.dig("sort", "schema", "default")).to eq(Api::TopicList::DEFAULT_SORT)
      expect(branches.dig("state", "schema")).to eq("$ref" => "#/components/schemas/BranchState")
      expect(branches.dig("current", "schema", "enum")).to match_array(Api::V1::BranchesController::CURRENT.keys.compact)
    end

    it "has the failure stages of a branch" do
      stages = schemas.dig("Branch", "properties", "failure_stage", "enum")
      expect(stages).to match_array(PatchBranch::FAILURE_STAGES + [ nil ])
    end

    it "has the contributor types of the memberships" do
      types = ContributorMembership.contributor_types.values
      expect(schemas.dig("ContributorType", "enum")).to match_array(types + [ nil ])
    end

    it "has the activity types the code creates" do
      sources = Dir[Rails.root.join("app/{models,services,controllers,jobs}/**/*.rb")]
      created = sources.flat_map { |file| File.readlines(file).grep(/activity_type\b.*"/).flat_map { |line| line.scan(/"(\w+)"/) } }

      expect(created.flatten.uniq).to match_array(Activity::TYPES)
      expect(schemas.dig("Activity", "properties", "type", "enum")).to match_array(Activity::TYPES)
      Activity::TYPES.each { |type| expect(schemas.dig("Activity", "properties", "type", "description")).to include("`#{type}`") }
    end

    it "has the kinds of record a note can mention" do
      handled = %w[User Team]
      builder = Rails.root.join("app/services/note_builder.rb").read
      helper = Rails.root.join("app/helpers/application_helper.rb").read[/def note_mention_label.*?\n  end/m]

      expect(builder.scan(/when "(\w+)" then \w+_ids <</).flatten).to match_array(handled)
      expect(helper.scan(/^    when (\w+)$/).flatten).to match_array(handled)
      expect(schemas.dig("NoteMention", "properties", "type", "enum")).to match_array(handled.map(&:downcase))
    end

    it "has the scopes of a saved search" do
      expect(schemas.dig("SavedSearch", "properties", "scope", "enum")).to match_array(SavedSearch.scopes.values)
    end

    it "has the values of the lineage data" do
      verdict = schemas.dig("CommitVerdict", "properties")
      group = schemas.dig("CommitGroup", "properties")
      shown = CommitVerdict::VERDICTS.select do |name|
        Lineage::ThreadPresenter.allocate.shown_on_thread?(CommitVerdict.new(verdict: name, origin: "trailer"))
      end

      expect(schemas.dig("StepKind", "enum")).to match_array(PatchsetLineage::STEP_KINDS)
      PatchsetLineage::STEP_KINDS.each { |kind| expect(schemas.dig("StepKind", "description")).to include("`#{kind}`") }
      [ schemas.dig("PatchsetStep", "properties"), schemas.dig("Lineage", "properties", "steps", "items", "properties") ].each do |step|
        expect(step["step_kind"]).to eq("$ref" => "#/components/schemas/StepKind")
      end
      expect(verdict.dig("verdict", "enum")).to match_array(shown)
      expect(verdict.dig("change_level", "enum")).to match_array(CommitVerdict::CHANGE_LEVELS + [ nil ])
      expect(verdict.dig("origin", "enum")).to match_array(CommitVerdict::ORIGINS)
      expect(verdict.dig("reviews", "items", "properties", "coverage", "enum")).to match_array(CommitVerdict::COVERAGES)
      expect(group.dig("link_source", "enum")).to match_array(CommitTopic::SOURCES)
      expect(group.dig("people", "items", "properties", "source", "enum")).to match_array(CommitPerson::SOURCES)
      expect(Api::V1::CommitPageData::LINEAGE_SOURCES).to match_array(CommitPerson::SOURCES)
    end

    it "keeps the lineage fields optional, so that they can be absent" do
      expect(schemas.dig("CommitGroup", "required")).not_to include("link_source", "verdict")
      expect(schemas.dig("CommitGroup", "properties", "people", "items", "required")).not_to include("source")
      expect(schemas.dig("Patchset", "required")).not_to include("lineage")
      expect(schemas.dig("Topic", "properties", "links", "required")).not_to include("lineage")
    end

    it "has the event types of the feed, each one a closed schema with its own record" do
      shared = %w[id type occurred_at recorded_at topic author]
      variants = schemas.dig("Event", "oneOf").map { |ref| schemas.fetch(ref.fetch("$ref").split("/").last) }
      operation = contract.document.dig("paths", "/events", "get")
      filter = operation["parameters"].find { |parameter| parameter["name"] == "types" }
      one = "(#{FeedEvent::TYPES.map { |type| Regexp.escape(type) }.join('|')})"

      expect(variants.map { |variant| variant.dig("properties", "type") }).to eq(FeedEvent::TYPES.map { |type| { "const" => type } })
      expect(variants.map { |variant| variant["properties"].keys - shared })
        .to eq(Api::V1::EventSerializer::PAYLOADS.values_at(*FeedEvent::TYPES).map { |key| [ key.to_s ] })
      variants.each do |variant|
        expect(variant["additionalProperties"]).to be(false)
        expect(variant["required"]).to match_array(variant["properties"].keys)
        expect(variant["properties"].slice("id", "recorded_at", "topic")).to eq(variants.first["properties"].slice("id", "recorded_at", "topic"))
      end
      expect(variants.map { |variant| variant["properties"].except(*shared).values.first["$ref"].split("/").last })
        .to eq(%w[Message Patchset Branch EventCiRun])
      expect(filter.dig("schema", "pattern")).to eq("^#{one}(,#{one})*$")
      FeedEvent::TYPES.each { |type| expect(operation["description"]).to include("`#{type}`") }
    end

    it "repeats CiRun in EventCiRun word for word, with the branch and the run before it added" do
      run, event = schemas.values_at("CiRun", "EventCiRun")
      added = %w[branch first_run previous_status]

      expect(event["properties"].except(*added)).to eq(run["properties"])
      expect(event["properties"]["branch"]).to eq("$ref" => "#/components/schemas/BranchBrief")
      expect(event["properties"]["first_run"]).to include("type" => "boolean")
      expect(event["properties"]["previous_status"]["oneOf"])
        .to eq([ { "$ref" => "#/components/schemas/CiRunStatus" }, { "type" => "null" } ])
      expect(event["required"]).to eq(run["required"] + added)
      expect(event["additionalProperties"]).to be(false)
    end

    it "has the commit roles in display order" do
      expect(schemas.dig("CommitRole", "enum")).to eq(CommitPerson::DISPLAY_ORDER)
      expect(CommitPerson::DISPLAY_ORDER).to match_array(CommitPerson::ROLES)
    end
  end

  describe "the description" do
    let(:document) { contract.document }
    let(:text) { document.dig("info", "description").gsub(/\s+/, " ") }
    let(:size) { ->(bytes) { ActiveSupport::NumberHelper.number_to_human_size(bytes) } }

    it "has the rate limits and the time limit of the code" do
      limits = Rails.configuration.x.api_rate_limit

      expect(text).to include("#{limits.anonymous} requests per IP address without a token", "#{limits.token} per token",
                              "counted per server process")
      expect(Rails.configuration.x.api_statement_timeout_ms).to eq(5000)
      expect(text).to include("longer than 5 seconds", "`query_too_expensive`")
    end

    it "has the limits of drafts" do
      expect(text).to include(
        "at most #{Api::V1::DraftsController::SUBJECT_LIMIT} characters", "the text #{size.call(Api::V1::DraftsController::BODY_BYTES)}",
        "one draft #{size.call(OutgoingDraft::MAX_ATTACHMENT_BYTES)} together", "a request #{size.call(Api::RequestBody::MAX_BYTES)}",
        "#{Drafts::TokenLimits::ACTIVE_DRAFTS} drafts that are not sent", "#{size.call(Drafts::TokenLimits::ATTACHMENT_BYTES)} of attachments",
        "more than #{Api::V1::BaseController::LOCK_TIMEOUT_MS / 1000} seconds"
      )
    end

    it "has the numbers of the feed" do
      feed = Api::EventFeed
      limits = Rails.configuration.x.api_rate_limit
      operation = document.dig("paths", "/events", "get")
      since = operation["parameters"].find { |parameter| parameter["name"] == "since" }
      days = feed::RETENTION.in_days.to_i
      seconds = feed::HOLD_BACK.to_i

      expect(text).to include("held back for #{seconds} seconds", "The feed keeps #{days} days", "410 `cursor_expired`",
                              "`since=#{feed::DEFAULT_SINCE}`", "Poll once a minute at most",
                              "#{limits.anonymous} calls a minute without a token, #{limits.token} with one")
      expect(operation["description"].gsub(/\s+/, " ")).to include("Events of the last #{seconds} seconds", "The feed keeps #{days} days")
      expect(since["description"].gsub(/\s+/, " ")).to include("#{days} days at most", "more than #{days} days back",
                                                               "Without `since` it is `#{feed::DEFAULT_SINCE}`")
      expect(since["description"].gsub(/\s+/, " ")).to include("a duration over #{days} days is 400")
      expect(since.dig("schema", "default")).to eq(feed::DEFAULT_SINCE)
      expect(since.dig("schema", "maxLength")).to eq(feed::MAX_SINCE)
      expect(Api::ErrorCodes::STATUSES["cursor_expired"]).to eq(410)
      expect(document.dig("paths", "/branches", "get", "description")).not_to include("walk the list")
    end

    it "says which CI runs the feed leaves out by default" do
      feed = Api::EventFeed
      operation = document.dig("paths", "/events", "get")
      ci_runs = operation["parameters"].find { |parameter| parameter["name"] == "ci_runs" }
      default = "By default the feed leaves out CI runs that only repeat the previous verdict of the same patchset"

      expect(ci_runs["schema"]).to include("enum" => feed::CI_RUNS, "default" => feed::DEFAULT_CI_RUNS)
      [ text, operation["description"].gsub(/\s+/, " ") ].each do |description|
        expect(description).to include(default, "`ci_runs=all`")
      end
      expect(operation["description"].gsub(/\s+/, " ")).to include("reported again, as a new event, if its verdict changes")
    end

    it "names the lists that are not paged, and they are the routes whose action takes no limit" do
      listed = text[/Three lists are not paged: (.*?) give everything at once/, 1].scan(/`([^`]+)`/).flatten
      unpaged = OpenapiHelper.operation_actions.select do |(template, verb), (controller, action)|
        verb == "get" && document.dig("paths", template, "get", "responses", "200", "content", "application/json", "schema")
                                 .to_s.include?("next_cursor") && !controller.allowed_query_params.fetch(action, []).include?("limit")
      end

      expect(listed).to match_array(%w[/mailing_lists /topics/{id}/commits /me/saved_searches])
      expect(unpaged.keys.map(&:first)).to match_array(listed)
    end

    it "says that the API cannot send, and how the owner sends" do
      expect(text).to include("The API cannot send mail.", "This API cannot send email. There is no send endpoint.",
                              "refuses to send a draft that changed after the owner confirmed it",
                              "`_method` and `X-HTTP-Method-Override` are ignored")
    end
  end

  it "has the same operations as the routes" do
    routed, problems = OpenapiHelper.route_operations

    expect(problems).to eq([])
    expect(routed).not_to be_empty
    undocumented = (routed - contract.operations).map { |template, verb| "#{verb.upcase} #{template}" }
    unrouted = (contract.operations - routed).map { |template, verb| "#{verb.upcase} #{template}" }
    expect(undocumented).to eq([]), "routes missing from openapi.yaml: #{undocumented.sort.join(', ')}"
    expect(unrouted).to eq([]), "openapi.yaml operations without a route: #{unrouted.sort.join(', ')}"
  end

  [ nil, "Bearer hko_nope" ].each do |authorization|
    context authorization ? "with an invalid token" : "without a token" do
      let(:headers) { { "Authorization" => authorization }.compact }

      it "is served as JSON" do
        get "/api/v1/openapi.json", headers: headers

        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("application/json")
        expect(response.headers["Cache-Control"]).to eq("max-age=3600, public")
        expect(JSON.parse(response.body)).to eq(contract.document)
      end

      it "is served as YAML" do
        get "/api/v1/openapi.yaml", headers: headers

        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("application/yaml")
        expect(response.headers["Cache-Control"]).to eq("max-age=3600, public")
        expect(YAML.safe_load(response.body)).to eq(contract.document)
      end
    end
  end

  it "takes no query parameters" do
    %w[openapi.json openapi.yaml].each do |name|
      get "/api/v1/#{name}?format=json"

      expect(response).to have_http_status(:bad_request), name
      expect(JSON.parse(response.body).dig("error", "code")).to eq("invalid_parameter")
    end
  end

  it "reads the file once outside development" do
    2.times { get "/api/v1/openapi.json" }
    expect(Api::V1::OpenapiController::SOURCE).not_to receive(:read)

    get "/api/v1/openapi.yaml"
    get "/api/v1/openapi.json"

    expect(response).to have_http_status(:ok)
  end

  it "reads the file each time in development" do
    allow(Rails.env).to receive(:development?).and_return(true)
    expect(Api::V1::OpenapiController::SOURCE).to receive(:read).twice.and_call_original

    2.times { get "/api/v1/openapi.yaml" }
  end
end
