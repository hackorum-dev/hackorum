# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API reference", type: :request do
  let(:openapi) { YAML.safe_load(Rails.root.join("docs/api/openapi.yaml").read) }
  let(:page) { Nokogiri::HTML5(response.body) }
  let(:ids) { page.css("[id]").map { |node| node["id"] } }

  def operations
    openapi.fetch("paths").flat_map do |path, item|
      item.slice(*Api::Reference::METHODS).map { |method, operation| [ method, path, operation ] }
    end
  end

  describe "with the document of the application" do
    before { get api_docs_path }

    it "is public and in the help layout" do
      expect(response).to have_http_status(:ok)
      expect(page.at_css("h1").text).to eq(openapi.dig("info", "title"))
      expect(page.at_css(".help-nav a.active").text).to eq("API reference")
      expect(response.body).to include('href="/api/v1/openapi.yaml"', 'href="/api/v1/openapi.json"', %(href="#{help_path('api')}"))
      expect(page.at_css(".api-docs-links a[href='/api/v1/guide.md']").text).to eq("Guide for agents")
      expect(page.at_css("#overview ~ p a[href='/api/v1/guide.md']")).to be_present
      expect(page.at_css("#overview ~ p a[href='/api/docs']")).to be_present
    end

    it "has every operation with its anchor, method and path" do
      expect(operations.size).to be >= 30

      operations.each do |method, path, operation|
        block = page.at_css("[id='op-#{operation.fetch('operationId')}']")
        expect(block).to be_present, "#{method} #{path} is not on the page"
        expect(block.at_css(".api-method").text).to eq(method.upcase)
        expect(block.at_css(".api-path").text).to eq(path)
        expect(block.at_css(".api-op-summary")&.text.to_s.squish).to eq(operation["summary"].to_s.delete("`").squish)
      end
      expect(page.css(".api-op").size).to eq(operations.size)
    end

    it "says for every operation what the token is for" do
      labels = operations.to_h do |_, _, operation|
        security = operation.fetch("security", openapi["security"])
        [ operation["operationId"], security.include?({}) ? "optional" : "required" ]
      end

      expect(labels.values.uniq).to contain_exactly("optional", "required")
      labels.each do |id, label|
        expect(page.at_css("[id='op-#{id}'] .api-token").text.squish).to eq("Token: #{label}")
      end
    end

    it "lists the parameters and the responses of every operation" do
      operations.each do |_, path, operation|
        block = page.at_css("[id='op-#{operation['operationId']}']")
        names = (openapi["paths"][path].fetch("parameters", []) + operation.fetch("parameters", [])).map do |param|
          param["name"] || openapi.dig("components", "parameters", param["$ref"].split("/").last, "name")
        end

        expect(block.css(".api-table tbody tr td:first-child code").map(&:text)).to match_array(names.uniq)
        expect(block.css(".api-responses > li > .api-response-head .api-status").map(&:text)).to eq(operation["responses"].keys.map(&:to_s))
      end
    end

    it "has every schema with its anchor, and every field of it" do
      schemas = openapi.dig("components", "schemas")
      expect(schemas.size).to be >= 40

      schemas.each do |name, schema|
        block = page.at_css("[id='schema-#{name}']")
        expect(block).to be_present, "schema #{name} is not on the page"
        expect(block.at_css("h3").text).to eq(name)
        fields = block.css("> .api-fields > .api-field > .api-field-head .api-field-name").map(&:text)
        expect(fields).to eq(schema.fetch("properties", {}).keys), "fields of #{name}"
      end
    end

    it "has every shared response" do
      openapi.dig("components", "responses").each_key do |name|
        expect(ids).to include("response-#{name}")
      end
    end

    it "has no dead link inside the page and no anchor twice" do
      targets = page.css("a[href^='#']").map { |link| link["href"].delete_prefix("#") }

      expect(targets.grep(/\Aschema-/).size).to be > 100
      expect(targets.grep(/\Aop-/).size).to eq(operations.size)
      expect(targets.uniq - ids).to be_empty
      expect(ids.tally.select { |_, count| count > 1 }).to be_empty
    end

    it "shows no reference of the document as text" do
      expect(response.body).not_to include("$ref")
      expect(response.body).not_to include("#/components/")
    end

    it "loads no script or other asset of its own" do
      main = page.at_css(".api-docs")

      expect(main.css("script, img, iframe, link, style, [style], [onclick]")).to be_empty
      expect(main.css("a[href^='http']").map { |link| link["href"] }).to all(start_with("http"))
    end

    it "can be cached, and is not sent again when it did not change" do
      expect(response.headers["Cache-Control"]).to eq("max-age=3600, public")
      expect(response.headers["ETag"]).to be_present
      expect(response.headers["Set-Cookie"]).to be_blank

      get api_docs_path, headers: { "If-None-Match" => response.headers["ETag"] }

      expect(response).to have_http_status(:not_modified)
    end
  end

  describe "for a signed-in user" do
    let(:user) { create(:user) }

    before { sign_in_as(user) }

    it "is not cached, the layout shows the user" do
      get api_docs_path

      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"].to_s).not_to include("public")
      expect(response.body).to include("Sign out", 'id="op-getMe"')
    end

    it "is linked from the API tokens page" do
      get settings_api_tokens_path

      expect(response.body).to include(%(href="#{api_docs_path}"))
    end
  end

  it "is linked from the help index and the help sidebar" do
    get help_index_path
    expect(Nokogiri::HTML5(response.body).css(".help-topic-list a[href='#{api_docs_path}'], .help-nav a[href='#{api_docs_path}']").size).to eq(2)

    get help_path("api")
    expect(Nokogiri::HTML5(response.body).at_css(".help-nav a[href='#{api_docs_path}']").text).to eq("API reference")
  end

  describe "with markup in the document" do
    let(:evil) { "<script>alert(1)</script>" }
    let(:pointer) { evil.gsub("/", "~1") }
    let(:document) do
      {
        "info" => { "title" => "T #{evil}", "description" => "Intro #{evil} <b>bold</b> [x](javascript:alert(1))\n\n<div onclick=\"x()\">block</div>" },
        "tags" => [ { "name" => "Tag #{evil}", "description" => evil } ],
        "paths" => {
          "/x/#{evil}" => {
            "get" => {
              "operationId" => "op#{evil}", "tags" => [ "Tag #{evil}" ], "summary" => "Sum #{evil}", "description" => "Desc #{evil}",
              "parameters" => [ { "name" => "p#{evil}", "in" => evil, "description" => evil,
                                  "schema" => { "type" => "string", "enum" => [ evil ], "default" => evil, "pattern" => evil, "format" => evil } } ],
              "requestBody" => { "description" => evil, "content" => { "text/#{evil}" => { "schema" => { "type" => evil } } } },
              "responses" => {
                evil => { "description" => evil, "headers" => { "H#{evil}" => { "description" => evil, "schema" => { "type" => "string" } } },
                          "content" => { "application/json" => { "schema" => { "$ref" => "#/components/schemas/S#{pointer}" } } } },
                "200" => { "$ref" => "#/components/responses/R#{pointer}" }
              }
            }
          }
        },
        "components" => {
          "responses" => { "R#{evil}" => { "description" => evil } },
          "schemas" => {
            "S#{evil}" => { "type" => "object", "description" => evil, "required" => [ "f#{evil}" ],
                            "properties" => { "f#{evil}" => { "type" => "string", "description" => evil, "enum" => [ evil ], "const" => evil,
                                                             "example" => evil },
                                              "g" => { "$ref" => "#/components/schemas/S#{pointer}" },
                                              "h" => { "$ref" => "#/components/schemas/Gone#{pointer}" } } }
          }
        }
      }
    end

    before do
      allow(Api::Reference).to receive(:current).and_return(Api::Reference.new(document))
      get api_docs_path
    end

    it "renders none of it as markup" do
      main = page.at_css(".api-docs")

      expect(response).to have_http_status(:ok)
      expect(main.css("script, b, div[onclick], [onclick]")).to be_empty
      expect(main.css("a").map { |link| link["href"] }.grep(/javascript/i)).to be_empty
      expect(main.to_html).not_to include("<script")
      expect(main.text.scan(evil).size).to be >= 25
      expect(main.at_css("h1").text).to eq("T #{evil}")
      expect(main.at_css(".api-table tbody code").text).to eq("p#{evil}")
      expect(main.css(".api-note code").map(&:text)).to include(evil)
    end

    it "still has working anchors" do
      targets = page.css(".api-docs a[href^='#']").map { |link| link["href"].delete_prefix("#") }

      expect(targets.grep(/\Aschema-/).size).to eq(3)
      expect(targets.grep(/\Aresponse-/).size).to eq(1)
      expect(targets.uniq - ids).to be_empty
    end
  end
end
