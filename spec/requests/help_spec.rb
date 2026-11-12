# frozen_string_literal: true

require 'rails_helper'

RSpec.describe "Help", type: :request do
  describe "GET /help" do
    it "returns the help index page" do
      get help_index_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Help")
      expect(response.body).to include("Advanced Search Guide")
    end
  end

  describe "GET /help/:slug" do
    it "renders the privacy policy with the anchors other pages link to" do
      get help_path("privacy")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="deleting-your-account"', 'id="recipients"', 'href="#recipients"')
    end

    context "with valid slug" do
      it "returns the help page" do
        get help_path("search")

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Advanced Search Guide")
      end

      it "renders markdown content as HTML" do
        get help_path("search")

        expect(response.body).to include("<h1")
        expect(response.body).to include("<code>")
        expect(response.body).to include("<pre>")
      end
    end

    context "with the API page" do
      let(:source) { Rails.root.join("app/views/help/pages/api.md").read }
      let(:openapi) { YAML.safe_load(Rails.root.join("docs/api/openapi.yaml").read) }

      # request lines of the page: full URLs, and "GET /path" in the text
      def page_requests
        source.scan(%r{(?:/api/v1|\b(GET|POST|PATCH|DELETE) )(/[\w{}/.@%-]+)(?:\?([^\s"`)]*))?}).map do |verb, path, query|
          template = path.gsub(%r{/\d+}, "/{id}").sub(%r{\A/people/[^/]+}, "/people/{email}")
          [ verb&.downcase, template, query.to_s.split("&").map { |pair| pair.split("=").first } ]
        end.uniq
      end

      def parameter_names(operation)
        operation.fetch("parameters", []).map do |param|
          param["name"] || openapi.dig("components", "parameters", param.fetch("$ref").split("/").last, "name")
        end
      end

      it "renders and is listed in the help index" do
        get help_path("api")

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('href="/api/v1/openapi.yaml"', 'href="/api/v1/openapi.json"')
        expect(response.body).to include(%(href="#{settings_api_tokens_path}"), %(href="#{help_path('search')}"))
        expect(response.body).to include('id="drafts"', 'href="#drafts"')
        expect(response.body).to include(%(href="#{api_docs_path}"), 'href="/api/v1/guide.md"')
        expect(response.body).to include('id="following-changes"', 'href="#following-changes"')

        get help_index_path

        expect(response.body).to include(%(href="#{help_path('api')}"))
      end

      it "is plain ASCII" do
        expect(source).to be_ascii_only
      end

      it "names only paths, methods and parameters the OpenAPI document has" do
        expect(page_requests.size).to be >= 10
        expect(page_requests.map(&:first)).to include("get", "post", nil)

        page_requests.each do |verb, path, params|
          item = openapi.dig("paths", path)
          expect(item).to be_present, "#{path} is not in openapi.yaml"
          operations = verb ? [ item[verb] ] : item.slice("get", "post", "patch", "delete").values
          expect(operations.compact).to be_present, "#{verb} #{path} is not in openapi.yaml"
          expect(params - operations.compact.flat_map { |operation| parameter_names(operation) }).to be_empty,
                 "#{path} does not take #{params.inspect}"
        end
      end

      it "explains the feed" do
        feed = Api::EventFeed

        expect(source).to include("## Following changes", "/api/v1/events?since=#{feed::DEFAULT_SINCE}&types=#{FeedEvent::PATCHSET_POSTED}\"",
                                  "The feed keeps #{feed::RETENTION.in_days.to_i} days", "410 with the code `cursor_expired`")
        expect(source).to include("By default the feed leaves out CI runs that only repeat the previous verdict of the same patchset",
                                  "`ci_runs=all`", "A run is reported again if its verdict changes")
        expect(source.scan(%r{^curl .*/api/v1/events}).size).to eq(1)
        expect(source).not_to match(/No change feed|you have to poll/)
      end

      it "uses placeholders for the ids of its examples" do
        expect(source).to include("`12345` always stands for the `id` of a thread", "`67890` for the `id` of a message",
                                  "`123` for the `id` of a draft")
        expect(source.scan(%r{/api/v1/(?:topics|messages|drafts|branches)/(\d+)}).flatten.uniq).to match_array(%w[12345 67890 123])
        expect(source.scan(/"reply_to_message_id": (\d+)/).flatten).to eq(%w[67890])
      end

      it "explains drafts, and that the API cannot send" do
        expect(source).to include("## Drafts", "/api/v1/drafts\"", "/api/v1/drafts/123/attachments\"", "content_base64")
        expect(source.scan("curl -X POST").size).to eq(2)
        expect(source).to match(/It cannot send email, and it never will: there is no send endpoint/)
        expect(source).to match(/It cannot send it\./)
        expect(source).to match(/refuses to send/)
        expect(source).not_to match(%r{/send\b|send_now})
      end

      it "names the labels the site puts on a draft from the API" do
        token = Struct.new(:name).new("agent")
        draft = Struct.new(:created_via_token, :last_edited_via_token).new(token, token)

        expect(ApplicationController.helpers.draft_api_labels(draft)).to eq([ "Drafted via API (agent)", "Edited via API (agent)" ])
        expect(source).to include('"Drafted via API"', '"Edited via API"')
      end

      it "has the limits of the code" do
        size = ->(bytes) { ActiveSupport::NumberHelper.number_to_human_size(bytes) }

        expect(source).to include(
          "at most #{Api::V1::DraftsController::SUBJECT_LIMIT} characters", "the text #{size.call(Api::V1::DraftsController::BODY_BYTES)}",
          "one draft can have #{size.call(OutgoingDraft::MAX_ATTACHMENT_BYTES)} together",
          "one request #{size.call(Api::RequestBody::MAX_BYTES)}", "at most #{size.call(Api::RequestBody::MAX_BYTES)}",
          "#{Drafts::TokenLimits::ACTIVE_DRAFTS} unsent drafts", "#{size.call(Drafts::TokenLimits::ATTACHMENT_BYTES)} of attachments",
          "#{Rails.configuration.x.api_rate_limit.anonymous} requests per IP address", "#{Rails.configuration.x.api_rate_limit.token} per token"
        )
      end
    end

    context "with invalid slug" do
      it "returns 404" do
        get help_path("nonexistent-page")

        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
