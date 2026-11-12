require "rails_helper"

RSpec.describe "API v1 attachments", type: :request do
  let(:message) { create(:message) }
  let(:keys) { %w[id message_id file_name content_type byte_size is_patch url content_url] }

  def body
    JSON.parse(response.body)
  end

  def error_code
    body.dig("error", "code")
  end

  def attachment(content, **attrs)
    create(:attachment, message: message, body: content && Base64.encode64(content), **attrs)
  end

  describe "GET /attachments/{id}" do
    it "gives the metadata without a token" do
      content = "diff --git a/src/x.c b/src/x.c\n" * 200
      shown = attachment(content, file_name: "v2-0001-fix.patch", content_type: "text/x-patch; charset=us-ascii")

      get "/api/v1/attachments/#{shown.id}"

      expect(response).to have_http_status(:ok)
      expect(response.headers["RateLimit-Limit"]).to be_present
      expect(body.keys).to match_array(keys)
      expect(body).to include("id" => shown.id, "message_id" => message.id, "file_name" => "v2-0001-fix.patch",
                              "content_type" => "text/x-patch; charset=us-ascii", "byte_size" => content.bytesize,
                              "is_patch" => true)
      expect(shown.body).to include("\n")
      expect(body["url"]).to end_with("/api/v1/attachments/#{shown.id}")
      expect(body["content_url"]).to end_with("/api/v1/attachments/#{shown.id}/content")
    end

    it "never selects the body" do
      shown = attachment("x" * 1000)

      queries = captured_queries { get "/api/v1/attachments/#{shown.id}" }

      on_attachments = queries.grep(/\battachments\b/i)
      expect(on_attachments.size).to eq(1)
      expect(on_attachments.grep(/\*|body|decode/i)).to be_empty
      expect(on_attachments.first).to include('"attachments"."byte_size"')
    end

    it "reads the body only for the content" do
      shown = attachment("x" * 1000)

      queries = captured_queries { get "/api/v1/attachments/#{shown.id}/content" }

      expect(queries.grep(/\battachments\b/i).grep(/\*|body/i).size).to eq(1)
    end

    it "sizes binary, empty and missing bodies" do
      binary = attachment((0..255).map(&:chr).join.b * 3, file_name: "a.bin", content_type: "application/octet-stream")
      empty = attachment("", file_name: "empty.txt")
      missing = attachment(nil, file_name: "missing.txt", content_type: nil)

      get "/api/v1/attachments/#{binary.id}"
      expect(body).to include("byte_size" => 768, "is_patch" => false)

      get "/api/v1/attachments/#{empty.id}"
      expect(body["byte_size"]).to eq(0)

      get "/api/v1/attachments/#{missing.id}"
      expect(body).to include("byte_size" => 0, "content_type" => nil)
    end

    it "decides is_patch by the name and the content type, never the content" do
      diff = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n"
      cases = [
        [ "a.patch", "text/plain", true ], [ "a.diff", "text/plain", true ], [ "A.PATCH", "text/plain", true ],
        [ "a.diffs", "text/plain", true ], [ "a.patch.gz", "text/plain", true ], [ "a.diff.txt", "text/plain", true ],
        [ "a.patch.bz2", "text/plain", true ], [ "patch", "text/plain", true ], [ "a.patch.3", "text/plain", true ],
        [ "changes.txt", "text/x-patch", true ], [ "changes.txt", "TEXT/X-DIFF; charset=utf-8", true ],
        [ "changes.txt", "text/plain", false ], [ "patch.png", "image/png", false ],
        [ "a.patch.zip", "text/plain", false ], [ "a.patch.nocfbot", "text/x-patch", false ],
        [ "no_cfbot-a.patch", "text/plain", false ]
      ]

      cases.each do |name, type, expected|
        get "/api/v1/attachments/#{attachment(diff, file_name: name, content_type: type).id}"

        expect(body["is_patch"]).to eq(expected), "#{name} (#{type}) gave #{body['is_patch']}"
      end
    end

    it "answers unknown and non-numeric ids with a JSON 404" do
      %w[0 999999999 99999999999999999999999999 abc 1x].each do |id|
        [ "", "/content" ].each do |rest|
          get "/api/v1/attachments/#{id}#{rest}"

          expect(response).to have_http_status(:not_found), "#{id}#{rest} gave #{response.status}"
          expect(error_code).to eq("not_found")
        end
      end
    end
  end

  describe "GET /attachments/{id}/content" do
    it "serves text as a plain text download" do
      shown = attachment("line one\nline two\n", file_name: "notes.txt", content_type: "text/plain; charset=us-ascii")

      get "/api/v1/attachments/#{shown.id}/content"

      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Type"]).to eq("text/plain; charset=utf-8")
      expect(response.headers["Content-Disposition"]).to start_with('attachment; filename="notes.txt"')
      expect(response.headers["RateLimit-Limit"]).to be_present
      expect(response.headers["Cache-Control"]).to eq("max-age=0, private, must-revalidate")
      expect(response.body).to eq("line one\nline two\n")
    end

    it "serves stored HTML as plain text, never as HTML" do
      html = "<script>alert(1)</script>"
      [ "text/html", "text/html; charset=utf-8", "application/xhtml+xml", "image/svg+xml" ].each do |type|
        shown = attachment(html, file_name: "page.html", content_type: type)

        get "/api/v1/attachments/#{shown.id}/content"

        expect(response.headers["Content-Type"]).to eq("text/plain; charset=utf-8"), "#{type} gave #{response.headers['Content-Type']}"
        expect(response.headers["Content-Disposition"]).to start_with("attachment;")
        expect(response.body).to eq(html)
      end
    end

    it "sends nosniff on its own, without the default headers" do
      shown = attachment("<script>alert(1)</script>", file_name: "page.html", content_type: "text/html")
      defaults = ActionDispatch::Response.default_headers.except("X-Content-Type-Options")
      allow(ActionDispatch::Response).to receive(:default_headers).and_return(defaults)

      get "/api/v1/attachments/#{shown.id}"
      expect(response).to have_http_status(:ok)
      expect(response.headers["X-Content-Type-Options"]).to be_nil

      get "/api/v1/attachments/#{shown.id}/content"
      expect(response).to have_http_status(:ok)
      expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
    end

    it "serves anything else as bytes" do
      bytes = (0..255).map(&:chr).join.b
      [ "image/png", "application/octet-stream", "TEXT/HTML", nil ].each do |type|
        shown = attachment(bytes, file_name: "blob.bin", content_type: type)

        get "/api/v1/attachments/#{shown.id}/content"

        expect(response).to have_http_status(:ok)
        expect(response.headers["Content-Type"]).to eq("application/octet-stream"), "#{type.inspect} gave #{response.headers['Content-Type']}"
        expect(response.headers["Content-Disposition"]).to start_with("attachment;")
        expect(response.body.b).to eq(bytes)
      end
    end

    it "sends text in another encoding unchanged" do
      latin1 = "caf\xE9\n".b
      shown = attachment(latin1, file_name: "notes.txt", content_type: "text/plain; charset=iso-8859-1")

      get "/api/v1/attachments/#{shown.id}/content"

      expect(response.headers["Content-Type"]).to eq("text/plain; charset=utf-8")
      expect(response.body.b).to eq(latin1)
    end

    it "cleans the file name" do
      {
        "/tmp/dir/diff" => 'filename="diff"',
        "..\\..\\evil.patch" => 'filename="evil.patch"',
        "a\r\nX-Evil: 1.txt" => 'filename="aX-Evil%3A 1.txt"',
        "dir/" => 'filename="dir"'
      }.each do |name, expected|
        shown = attachment("x", file_name: name)

        get "/api/v1/attachments/#{shown.id}/content"

        expect(response).to have_http_status(:ok)
        expect(response.headers["Content-Disposition"]).to include(expected), "#{name.inspect} gave #{response.headers['Content-Disposition']}"
        expect(response.headers["Content-Disposition"]).not_to match(/[\r\n]/)
      end

      [ " / ", "..", ".", "dir/..", "a\\." ].each do |name|
        nameless = attachment("x", file_name: name)
        get "/api/v1/attachments/#{nameless.id}/content"
        expect(response.headers["Content-Disposition"]).to include(%(filename="attachment-#{nameless.id}")), "#{name.inspect} gave #{response.headers['Content-Disposition']}"
      end
    end

    it "caps the file name, keeping the extension" do
      {
        "#{'a' * 4994}.patch" => "#{'a' * 194}.patch",
        "b" * 5000 => "b" * 200,
        "c.#{'d' * 4998}" => "c.#{'d' * 198}",
        "#{'e' * 200}.gz" => "#{'e' * 197}.gz",
        "#{'f' * 196}.txt" => "#{'f' * 196}.txt"
      }.each do |name, expected|
        shown = attachment("x", file_name: name)

        get "/api/v1/attachments/#{shown.id}/content"

        expect(response).to have_http_status(:ok)
        expect(response.headers["Content-Disposition"]).to include(%(filename="#{expected}")), "#{name.first(20)} (#{name.length})"
      end
    end

    it "answers an empty or missing body with 404" do
      [ attachment(""), attachment(nil) ].each do |shown|
        get "/api/v1/attachments/#{shown.id}/content"

        expect(response).to have_http_status(:not_found)
        expect(error_code).to eq("not_found")
      end
    end
  end
end
