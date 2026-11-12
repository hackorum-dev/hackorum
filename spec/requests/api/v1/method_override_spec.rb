require "rails_helper"

RSpec.describe "API v1 method override", type: :request do
  let(:user) { create(:user) }
  let(:auth) { { "Authorization" => "Bearer #{ApiToken.issue!(user: user, name: 'agent').last}" } }
  let!(:draft) { create(:outgoing_draft, user: user) }
  let(:path) { "/api/v1/drafts/#{draft.id}" }

  def expect_no_such_endpoint
    expect(response).to have_http_status(:not_found)
    expect(response.media_type).to eq("application/json")
    expect(JSON.parse(response.body).dig("error", "code")).to eq("not_found")
    expect(OutgoingDraft.exists?(draft.id)).to be(true)
  end

  it "does not turn a POST into a DELETE, by form field or by header" do
    post path, params: { _method: "delete" }, headers: auth
    expect_no_such_endpoint

    post path, headers: auth.merge("X-HTTP-Method-Override" => "DELETE")
    expect_no_such_endpoint

    post path, params: {}.to_json, headers: auth.merge("X-HTTP-Method-Override" => "DELETE", "Content-Type" => "application/json")
    expect_no_such_endpoint

    post "#{path}?_method=delete", headers: auth
    expect_no_such_endpoint
  end

  it "does not turn a POST into a PATCH" do
    before = draft.reload.attributes

    post path, params: { _method: "patch", body: "x" }, headers: auth

    expect_no_such_endpoint
    expect(draft.reload.attributes).to eq(before)
  end

  it "still deletes with DELETE" do
    delete path, headers: auth

    expect(response).to have_http_status(:no_content)
    expect(OutgoingDraft.exists?(draft.id)).to be(false)
  end

  it "leaves the override to the forms of the site" do
    author = create(:user)
    note = Note.create!(topic: create(:topic), author: author, body: "a note")
    sign_in_as(author)

    post "/notes/#{note.id}", params: { _method: "delete" }

    expect(response).to have_http_status(:found).or have_http_status(:see_other)
    expect(Note.active.exists?(note.id)).to be(false)
  end

  describe "a form body" do
    let(:boundary) { "XnJLe9ZIbbGUYtzPQJ16u1" }
    let(:multipart) do
      "--#{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.bin\"\r\n" \
        "Content-Type: application/octet-stream\r\n\r\n#{'A' * 6.megabytes}\r\n--#{boundary}--\r\n"
    end
    let(:headers) { auth.merge("Content-Type" => "multipart/form-data; boundary=#{boundary}") }

    it "is never parsed, over the size limit" do
      expect(Rack::Multipart).not_to receive(:parse_multipart)
      expect(Rack::Multipart::Parser).not_to receive(:parse)

      [ "/api/v1/drafts", path, "#{path}/attachments", "/api/v1/nope" ].each do |target|
        post target, params: multipart, headers: headers

        expect(response).to have_http_status(:content_too_large), target
        expect(JSON.parse(response.body).dig("error", "code")).to eq("payload_too_large")
      end
    end

    it "is refused as a media type within the limit, and not parsed on an unknown path" do
      post "/api/v1/drafts", params: { reply_to_message_id: 1 }, headers: auth
      expect(response).to have_http_status(:unsupported_media_type)

      expect(Rack::Multipart).not_to receive(:parse_multipart)
      post "/api/v1/nope", params: multipart.sub("A" * 6.megabytes, "A"), headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
