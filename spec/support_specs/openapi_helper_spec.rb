require "rails_helper"

RSpec.describe OpenapiHelper do
  let(:error_schema) do
    {
      "type" => "object", "additionalProperties" => false, "required" => [ "error" ],
      "properties" => { "error" => { "type" => "object" } }
    }
  end
  let(:thing_schema) do
    {
      "type" => "object", "additionalProperties" => false, "required" => [ "id" ],
      "properties" => { "id" => { "type" => "integer" } }
    }
  end
  let(:thing_response) do
    { "description" => "ok", "content" => { "application/json" => { "schema" => { "$ref" => "#/components/schemas/Thing" } } } }
  end
  let(:responses) do
    {
      "200" => thing_response,
      "204" => { "description" => "gone" },
      "default" => { "$ref" => "#/components/responses/Error" }
    }
  end
  let(:document) do
    {
      "openapi" => "3.1.0",
      "info" => { "title" => "t", "version" => "1" },
      "paths" => {
        "/things/search" => { "get" => { "responses" => { "200" => { "description" => "none" } } } },
        "/things/{id}" => { "get" => { "responses" => responses }, "delete" => { "responses" => responses } }
      },
      "components" => {
        "responses" => {
          "Error" => { "$ref" => "#/components/responses/RealError" },
          "RealError" => {
            "description" => "error",
            "content" => { "application/json" => { "schema" => { "$ref" => "#/components/schemas/Error" } } }
          }
        },
        "schemas" => { "Error" => error_schema, "Thing" => thing_schema }
      }
    }
  end
  let(:contract) { OpenapiHelper::Contract.new(document) }

  def violations(status:, body: "", media_type: nil, verb: "get", template: "/things/{id}")
    contract.violations(template: template, verb: verb, status: status, media_type: media_type, body: body)
  end

  def json(status, body, **rest)
    violations(status: status, body: body.is_a?(String) ? body : body.to_json, media_type: "application/json", **rest)
  end

  describe ".duplicate_keys" do
    it "finds a key that a mapping has twice, at any depth" do
      source = <<~YAML
        paths:
          /a:
            get:
              summary: one
              responses:
                "200":
                  description: ok
              summary: two
          /b:
            - name: x
              in: query
              name: y
        info: {title: a, title: b}
      YAML

      expect(described_class.duplicate_keys(Psych.parse_stream(source)))
        .to match_array([ "paths//a/get: summary", "paths//b/0: name", "info: title" ])
    end

    it "finds none in a clean document" do
      expect(described_class.duplicate_keys(Psych.parse_stream("a: {b: 1, c: [{b: 1}, {b: 2}]}\nd: 1\n"))).to eq([])
    end
  end

  describe ".template" do
    it "takes the template from the matched route" do
      expect(described_class.template("/api/v1/topics/:id(.:format)", "api/v1/topics")).to eq("/topics/{id}")
      expect(described_class.template("/api/v1/topics/search", "api/v1/topics")).to eq("/topics/search")
      expect(described_class.template("/api/v1/topics/:topic_id/messages/:id", "api/v1/messages"))
        .to eq("/topics/{topic_id}/messages/{id}")
    end

    it "has none for the catch-all, a missing route and other paths" do
      expect(described_class.template("/api/v1(/*unmatched)", "api/v1/errors")).to be_nil
      expect(described_class.template(nil, nil)).to be_nil
      expect(described_class.template("/help(.:format)", "help")).to be_nil
    end
  end

  describe "Contract#violations" do
    it "accepts a documented response" do
      expect(json(200, { id: 1 })).to eq([])
    end

    it "reports a body that does not match the schema" do
      expect(json(200, { id: "x" }).join).to include("integer")
      expect(json(200, { id: 1, extra: 2 })).not_to be_empty
    end

    it "does not confuse a literal path with a parameter" do
      expect(violations(status: 200, template: "/things/search")).to eq([])
      expect(json(200, { id: 1 }, template: "/things/search").join).to include("no content")
    end

    it "reports an unknown template and verb" do
      expect(violations(status: 200, template: "/nope").join).to include("not in the document")
      expect(violations(status: 200, verb: "post").join).to include("not in the document")
    end

    it "uses default for errors only" do
      expect(json(422, { error: {} })).to eq([])
      expect(json(201, { error: {} }).join).to include("201 is not documented")
      expect(json(302, { error: {} }).join).to include("302 is not documented")
    end

    it "never matches an Integer status key" do
      responses.replace(200 => thing_response)
      expect(json(200, { id: 1 }).join).to include("200 is not documented")
    end

    it "follows a ref to a ref" do
      expect(json(500, { nope: 1 })).not_to be_empty
    end

    it "reports a dangling ref" do
      responses["default"] = { "$ref" => "#/components/responses/Missing" }
      expect(json(500, { error: {} }).join).to include("#/components/responses/Missing does not resolve")
    end

    it "reports a ref loop" do
      document["components"]["responses"]["RealError"] = { "$ref" => "#/components/responses/Error" }
      expect(json(500, { error: {} }).join).to include("loop")
    end

    it "wants an empty body when no content is documented" do
      expect(violations(status: 204)).to eq([])
      expect(json(204, { id: 1 }).join).to include("no content")
    end

    it "wants a documented media type" do
      expect(violations(status: 200, body: "<p>", media_type: "text/html").join).to include("text/html")
      expect(violations(status: 200).join).to include("media type")
    end

    it "reports an empty or broken JSON body" do
      expect(json(200, "").join).to include("empty")
      expect(json(200, "{").join).to include("not JSON")
    end

    it "wants a schema for a JSON response" do
      thing_response["content"]["application/json"] = {}
      expect(json(200, { id: 1 }).join).to include("no schema")
    end

    it "takes any body for other media types" do
      thing_response["content"] = { "application/yaml" => { "schema" => { "type" => "string" } } }
      expect(violations(status: 200, body: "a: 1", media_type: "application/yaml")).to eq([])
    end

    it "takes a download in one of the listed types, and no other" do
      thing_response["content"] = {
        "text/plain" => { "schema" => { "type" => "string" } },
        "application/octet-stream" => { "schema" => { "type" => "string", "format" => "binary" } }
      }
      bytes = "\x00\xFF{not json".b

      expect(violations(status: 200, body: bytes, media_type: "text/plain")).to eq([])
      expect(violations(status: 200, body: bytes, media_type: "application/octet-stream")).to eq([])
      expect(violations(status: 200, body: bytes, media_type: "text/html").join).to include("text/html", "text/plain")
      expect(json(200, { id: 1 }).join).to include("application/json")
      expect(json(404, { nope: 1 })).not_to be_empty
    end

    it "checks HEAD against GET, without the body" do
      expect(violations(status: 200, verb: "head", media_type: "application/json")).to eq([])
      expect(violations(status: 201, verb: "head").join).to include("201 is not documented")
      expect(violations(status: 200, verb: "head", media_type: "text/html").join).to include("text/html")
    end
  end

  describe "Contract#unknown_path_violations" do
    def unknown(status, body, media_type: "application/json")
      contract.unknown_path_violations(status: status, media_type: media_type, body: body.to_json)
    end

    it "accepts an error" do
      expect(unknown(404, { error: {} })).to eq([])
      expect(unknown(400, { error: {} })).to eq([])
    end

    it "rejects other statuses" do
      expect(unknown(200, { error: {} }).join).to include("200")
      expect(unknown(401, { error: {} }).join).to include("401")
    end

    it "rejects another shape" do
      expect(unknown(404, { message: "x" })).not_to be_empty
      expect(unknown(404, { error: {} }, media_type: "text/html").join).to include("text/html")
    end

    it "needs the Error schema" do
      document["components"]["schemas"].delete("Error")
      expect(unknown(404, { error: {} }).join).to include("#/components/schemas/Error")
    end
  end

  describe "coverage" do
    it "lists the operations" do
      expect(contract.operations).to eq(Set[[ "/things/search", "get" ], [ "/things/{id}", "get" ], [ "/things/{id}", "delete" ]])
    end

    it "wants a validated 2xx for each operation" do
      contract.record("/things/{id}", "get", 200)
      contract.record("/things/{id}", "delete", 404)
      contract.record("/things/search", "head", 200)

      expect(contract.unexercised).to eq([ [ "/things/search", "get" ], [ "/things/{id}", "delete" ] ])
    end
  end

  describe ".route_operations" do
    def draw(&block)
      ActionDispatch::Routing::RouteSet.new.tap { |set| set.draw(&block) }.routes
    end

    it "maps routes to templates and verbs" do
      routes = draw do
        get "help", to: "help#show"
        namespace :api, defaults: { format: :json } do
          namespace :v1 do
            get "topics/search", to: "topics#search", format: false
            resources :topics, only: [ :show, :update ] do
              resources :messages, only: [ :index, :create ]
            end
            get "legacy", to: "topics#index"
            match "both", to: "topics#index", via: [ :get, :post ]
            match "(*unmatched)", to: "errors#not_found", via: :all
          end
        end
      end

      operations, problems = described_class.route_operations(routes)

      expect(problems).to eq([])
      expect(operations).to eq(Set[
        [ "/topics/search", "get" ], [ "/topics/{id}", "get" ], [ "/topics/{id}", "patch" ], [ "/topics/{id}", "put" ],
        [ "/topics/{topic_id}/messages", "get" ], [ "/topics/{topic_id}/messages", "post" ],
        [ "/legacy", "get" ], [ "/both", "get" ], [ "/both", "post" ]
      ])
    end

    it "names routes it cannot map" do
      routes = draw do
        scope "api/v1" do
          get "files/*path", to: "files#show", format: false
          get "a(/:b)", to: "files#show", format: false
          match "any", to: "files#show", via: :all, format: false
        end
      end

      operations, problems = described_class.route_operations(routes)

      expect(operations).to be_empty
      expect(problems.size).to eq(3)
      expect(problems.join("\n")).to include("/api/v1/files/*path", "/api/v1/a(/:b)", "/api/v1/any")
    end
  end

  describe "lints" do
    it "passes a clean document" do
      expect(contract.lint).to eq([])
    end

    it "wants String response keys" do
      responses[200] = responses.delete("200")
      responses["2XX"] = thing_response
      expect(contract.lint.join("\n")).to include("200 (Integer)", "2XX")
    end

    it "wants closed objects" do
      thing_schema.delete("additionalProperties")
      thing_schema["properties"]["nested"] = { "type" => "array", "items" => { "properties" => { "a" => {} } } }
      expect(contract.lint.join("\n")).to include("#/components/schemas/Thing has properties",
                                                   "#/components/schemas/Thing/properties/nested/items has properties")
    end

    it "takes unevaluatedProperties and a property called properties" do
      thing_schema.delete("additionalProperties")
      thing_schema["unevaluatedProperties"] = false
      thing_schema["properties"]["properties"] = { "type" => "object" }
      expect(contract.lint).to eq([])
    end

    it "finds inline schemas" do
      thing_response["content"]["application/json"]["schema"] = { "properties" => { "a" => {} } }
      expect(contract.lint.join).to include("200/content/application~1json/schema has properties")
    end

    it "wants required names to exist" do
      thing_schema["required"] << "name"
      expect(contract.lint.join).to include("requires name")
    end

    it "wants every ref to resolve" do
      thing_schema["properties"]["other"] = { "$ref" => "#/components/schemas/Other" }
      expect(contract.lint.join).to include("#/components/schemas/Other does not resolve")
    end

    it "wants security names to exist" do
      document["security"] = [ {}, { "bearer" => [] } ]
      document["paths"]["/things/{id}"]["get"]["security"] = [ { "cookie" => [] } ]
      expect(contract.lint.join("\n")).to include("bearer", "cookie")

      document["components"]["securitySchemes"] = { "bearer" => {}, "cookie" => {} }
      expect(contract.lint).to eq([])
    end

    describe "of request bodies" do
      let(:body) do
        { "required" => true, "content" => { "application/json" => { "schema" => { "$ref" => "#/components/schemas/Thing" } } } }
      end
      let(:item) { document["paths"]["/things/{id}"] }

      before { item["patch"] = { "requestBody" => body, "responses" => responses } }

      it "passes a required JSON body with a closed schema" do
        expect(contract.lint).to eq([])
        expect(contract.request_body_schema("/things/{id}", "patch")).to eq(thing_schema)
        expect(contract.request_body_schema("/things/{id}", "get")).to be_nil
      end

      it "wants one on POST, PUT and PATCH, and none elsewhere" do
        item["post"] = { "responses" => responses }
        item["delete"]["requestBody"] = body

        expect(contract.lint).to contain_exactly(
          "#/paths/~1things~1{id}/post/requestBody: a POST operation must document its request body",
          "#/paths/~1things~1{id}/delete/requestBody: a DELETE operation takes no request body"
        )
      end

      it "wants it required and JSON only" do
        body.delete("required")
        body["content"]["multipart/form-data"] = { "schema" => { "$ref" => "#/components/schemas/Thing" } }

        expect(contract.lint.join("\n")).to include("requestBody must be required", "application/json as its only content")
      end

      it "wants a closed object" do
        [ { "type" => "string" }, { "type" => "object", "properties" => {}, "additionalProperties" => true },
          { "type" => "object", "additionalProperties" => false } ].each do |schema|
          body["content"]["application/json"]["schema"] = schema

          expect(contract.lint.join).to include("requestBody: the schema must be an object")
        end
      end

      it "checks the body of a request that succeeded" do
        expect(contract.request_violations("/things/{id}", "patch", { id: 1 }.to_json)).to eq([])
        expect(contract.request_violations("/things/{id}", "patch", { id: 1, more: 2 }.to_json).join).to include("request body:")
        expect(contract.request_violations("/things/{id}", "patch", "").join).to include("request body: the body is empty")
        expect(contract.request_violations("/things/{id}", "get", "anything")).to eq([])
      end
    end
  end

  describe "request hook", type: :request, openapi: true do
    let(:recorder) do
      Class.new do
        attr_reader :seen

        def check(request, response)
          (@seen ||= []) << [ request.method, request.path, response.status ]
          nil
        end
      end.new
    end
    let(:me_schema) { { "type" => "object", "required" => [ "nope" ] } }
    let(:fake) do
      document["paths"] = {
        "/me" => { "get" => { "responses" => {
          "401" => { "description" => "x", "content" => { "application/json" => { "schema" => me_schema } } }
        } } },
        "/openapi.json" => { "get" => { "responses" => {
          "200" => { "description" => "x", "content" => { "application/json" => { "schema" => {} } } }
        } } }
      }
      OpenapiHelper::Contract.new(document)
    end

    attr_writer :openapi_contract

    def openapi_contract
      @openapi_contract || super
    end

    it "checks against the real document by default" do
      expect(integration_session.openapi_example.openapi_contract).to be(OpenapiHelper.contract)
    end

    it "fails on a bad response followed by a good one" do
      self.openapi_contract = fake

      expect do
        get "/api/v1/me"
        get "/api/v1/openapi.json"
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError, %r{GET /api/v1/me -> 401.*nope}m)
    end

    it "passes and records good responses" do
      me_schema.clear
      self.openapi_contract = fake

      get "/api/v1/me"
      get "/api/v1/openapi.json"

      expect(fake.validated).to eq(Set[[ "/me", "get", 401 ], [ "/openapi.json", "get", 200 ]])
    end

    it "fails on an undocumented success" do
      fake.document["paths"]["/openapi.json"]["get"]["responses"] = { "default" => { "$ref" => "#/components/responses/Error" } }
      self.openapi_contract = fake

      expect { get "/api/v1/openapi.json" }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, %r{GET /api/v1/openapi.json -> 200.*200 is not documented}m)
    end

    it "checks unknown paths as errors" do
      self.openapi_contract = fake

      get "/api/v1/no/such/thing"
      post "/api/v1"

      allow_any_instance_of(Api::V1::ErrorsController).to receive(:not_found) { |c| c.render json: { ok: true } }
      expect { get "/api/v1/no/such/thing" }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, %r{GET /api/v1/no/such/thing -> 200.*unknown path}m)
    end

    it "sees every verb and followed redirects, and nothing outside the API" do
      self.openapi_contract = recorder
      allow_any_instance_of(Api::V1::ErrorsController).to receive(:not_found) { |c| c.redirect_to "/api/v1/me" }

      get "/api/v1/me"
      head "/api/v1/me"
      post "/api/v1/me"
      follow_redirect!
      patch "/api/v1/x"
      put "/api/v1/x"
      delete "/api/v1/x"
      get "/help"
      get "/api/lineage/queue"
      get "/api/v10/me"

      expect(recorder.seen).to eq([
        [ "GET", "/api/v1/me", 401 ], [ "HEAD", "/api/v1/me", 401 ], [ "POST", "/api/v1/me", 302 ],
        [ "GET", "/api/v1/me", 401 ], [ "PATCH", "/api/v1/x", 302 ], [ "PUT", "/api/v1/x", 302 ],
        [ "DELETE", "/api/v1/x", 302 ]
      ])
    end

    it "checks requests no route matched as errors" do
      self.openapi_contract = fake
      config = Rails.application.env_config
      saved = config.slice("action_dispatch.show_exceptions", "action_dispatch.show_detailed_exceptions")
      config["action_dispatch.show_exceptions"] = :all

      expect { get "/api/v1/a%ffb" }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, %r{GET /api/v1/a%FFb -> 400 \(unknown path\).*text/html}m)

      config["action_dispatch.show_detailed_exceptions"] = false
      get "/api/v1/a%ffb"

      expect(response).to have_http_status(:bad_request)
      expect(fake.validated).to be_empty
    ensure
      config.merge!(saved)
    end

    it "sees throttled requests as their operation" do
      self.openapi_contract = fake
      limits = Rails.configuration.x.api_rate_limit
      old_store, old_limit = Rack::Attack.cache.store, limits.anonymous
      Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
      limits.anonymous = 0

      expect { get "/api/v1/me" }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, %r{GET /api/v1/me -> 429 \(GET /me\).*429 is not documented}m)
    ensure
      Rack::Attack.cache.store = old_store
      limits.anonymous = old_limit
    end
  end

  describe ".full_run?" do
    let(:dir) { Rails.root.join("spec/requests/api/v1").to_s }
    let(:files) { Dir[File.join(dir, "**/*_spec.rb")] }

    def config(files_to_run, inclusions: {}, exclusions: {}, only_failures: false, dry_run: false)
      double(files_to_run: files_to_run, only_failures?: only_failures, dry_run?: dry_run,
             inclusion_filter: double(rules: inclusions), exclusion_filter: double(rules: exclusions))
    end

    it "is true when the whole directory runs unfiltered" do
      expect(described_class.full_run?(config(files + [ "/x/spec/models/a_spec.rb" ]))).to be(true)
    end

    it "is false for a partial or filtered run" do
      expect(described_class.full_run?(config(files.drop(1)))).to be(false)
      expect(described_class.full_run?(config([ "/x/spec/models/a_spec.rb" ]))).to be(false)
      expect(described_class.full_run?(config(files, inclusions: { locations: {} }))).to be(false)
      expect(described_class.full_run?(config(files, inclusions: { full_description: /x/ }))).to be(false)
      expect(described_class.full_run?(config(files, exclusions: { slow: true }))).to be(false)
      expect(described_class.full_run?(config(files, only_failures: true))).to be(false)
      expect(described_class.full_run?(config(files, dry_run: true))).to be(false)
    end
  end
end
