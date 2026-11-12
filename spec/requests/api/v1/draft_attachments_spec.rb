require "rails_helper"

RSpec.describe "API v1 draft attachments", type: :request do
  let(:user) { create(:user, username: "alice") }
  let(:other) { create(:user, username: "bob") }
  let!(:identity) { create(:identity, user: user, email: "alice@example.org", refresh_token: "r", send_authorized_at: 1.hour.ago) }
  let!(:sender) { create(:alias, user: user, email: "alice@example.org", name: "Alice A") }
  let(:list) { create(:mailing_list, post_address: "list@example.org") }
  let(:topic) { create(:topic, mailing_lists: [ list ]) }
  let(:parent) { create(:message, topic: topic) }
  let(:issued) { ApiToken.issue!(user: user, name: "agent") }
  let(:token) { issued.first }
  let(:auth) { { "Authorization" => "Bearer #{issued.last}" } }
  let(:other_auth) { { "Authorization" => "Bearer #{ApiToken.issue!(user: other, name: 'laptop').last}" } }
  let(:fixed) { [] }
  let(:detail_keys) do
    %w[id url html_url state topic reply_to_message_id subject body sender recipients recipients_error attachments
       last_send_error created_via last_edited_via sent_message_id sent_at created_at updated_at]
  end
  let(:cap) { OutgoingDraft::MAX_ATTACHMENT_BYTES }
  let!(:draft) { draft_of(user, updated_at: 1.hour.ago) }

  after do
    expect(OutgoingDraft.where.not(status: "idle").pluck(:id)).to match_array(fixed.map(&:id))
    expect(OutgoingDraft.where.not(sending_started_at: nil).pluck(:id) - fixed.map(&:id)).to eq([])
  end

  around do |example|
    with_env("HACKORUM_DEV_REPLY_TO" => "dev@example.net") { example.run }
  end

  def body
    JSON.parse(response.body)
  end

  def error
    body.fetch("error")
  end

  def expect_error(status, code, message = nil)
    expect(response).to have_http_status(status)
    expect(error["code"]).to eq(code)
    expect(error["message"]).to match(message) if message
  end

  def json(headers)
    headers.merge("Content-Type" => "application/json")
  end

  def draft_of(owner, **attrs)
    attrs = { identity: identity, sender_alias: sender }.merge(attrs) if owner == user
    create(:outgoing_draft, user: owner, topic: topic, reply_to_message: create(:message, topic: topic), **attrs)
  end

  def files_path(of = draft)
    "/api/v1/drafts/#{of.id}/attachments"
  end

  def b64(bytes)
    Base64.strict_encode64(bytes)
  end

  def upload(fields, to: draft, headers: auth)
    post files_path(to), params: fields.is_a?(String) ? fields : fields.to_json, headers: json(headers)
  end

  def upload_bytes(bytes, name: "fix.patch", **options)
    upload({ file_name: name, content_base64: b64(bytes) }, **options)
  end

  def remove(attachment, from: draft, headers: auth)
    delete "#{files_path(from)}/#{attachment.id}", headers: headers
  end

  def set_state(of, status)
    stamps = { "sending" => { sending_started_at: Time.current }, "sent" => { sent_at: Time.current, sending_started_at: nil } }
    of.update_columns(status: status, **stamps.fetch(status))
    fixed << of unless fixed.include?(of)
  end

  def unchanged(*drafts)
    drafts = [ draft ] if drafts.empty?
    before = drafts.map { |row| row.reload.attributes }
    files = DraftAttachment.order(:id).map(&:attributes)
    yield
    expect(drafts.map { |row| row.reload.attributes }).to eq(before)
    expect(DraftAttachment.order(:id).map(&:attributes)).to eq(files)
  end

  describe "the promise not to send" do
    it "has the two routes of the attachments and no other" do
      routes = Rails.application.routes.routes.select { |route| route.defaults[:controller] == "api/v1/draft_attachments" }

      expect(routes.map { |route| [ route.verb, route.path.spec.to_s.delete_suffix("(.:format)"), route.defaults[:action] ] })
        .to match_array([
          [ "POST", "/api/v1/drafts/:id/attachments", "create" ],
          [ "DELETE", "/api/v1/drafts/:id/attachments/:attachment_id", "destroy" ]
        ])
    end
  end

  describe "POST /drafts/{id}/attachments" do
    it "stores the file and gives the draft with it" do
      was = draft.updated_at

      upload({ file_name: "v1-0001-fix.patch", content_type: "text/x-diff", content_base64: b64("diff\n") })

      expect(response).to have_http_status(:created)
      row = draft.draft_attachments.sole
      expect(row).to have_attributes(file_name: "v1-0001-fix.patch", content_type: "text/x-diff", byte_size: 5, decoded_body: "diff\n")
      expect(body.keys).to eq(detail_keys)
      expect(body["attachments"]).to eq([
        { "id" => row.id, "file_name" => "v1-0001-fix.patch", "content_type" => "text/x-diff", "byte_size" => 5 }
      ])
      expect(body).to include("id" => draft.id, "state" => "in_progress", "last_edited_via" => { "token_name" => "agent" })
      expect(draft.reload.updated_at).to be > was
      expect(draft.last_edited_via_token).to eq(token)
      expect(body["updated_at"]).to eq(draft.updated_at.as_json)
      expect(response.body).not_to include(b64("diff\n"))
      expect(response.headers["Vary"].to_s).to include("Authorization")
      expect(response.headers["Cache-Control"].to_s).not_to include("public")

      answer = body
      get "/api/v1/drafts/#{draft.id}", headers: auth
      expect(body).to eq(answer)
    end

    it "stores what an upload on the site stores for the same bytes, and the composer shows it" do
      bytes = (0..255).map(&:chr).join.b * 40
      on_site = draft_of(user)
      sign_in_as(user)
      file = Rack::Test::UploadedFile.new(StringIO.new(bytes), "text/x-diff", true, original_filename: "dir/v2 \"fix\".patch")
      post draft_attachments_path(on_site), params: { files: [ file ] }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
      expect(response).to have_http_status(:ok)

      upload({ file_name: "dir/v2 \"fix\".patch", content_type: "text/x-diff", content_base64: b64(bytes) })
      expect(response).to have_http_status(:created)

      columns = %w[file_name content_type body byte_size]
      expect(draft.draft_attachments.sole.attributes.slice(*columns)).to eq(on_site.draft_attachments.sole.attributes.slice(*columns))
      expect(draft.draft_attachments.sole).to have_attributes(file_name: "v2 _fix_.patch", decoded_body: bytes)

      get edit_draft_path(draft)
      expect(response.body).to include("v2 _fix_.patch")
    end

    it "is in the mail the site would build" do
      upload({ file_name: "fix.patch", content_type: "text/x-diff", content_base64: b64("diff\n") })

      part = Mail.new(Outgoing::MessageBuilder.build(draft.reload).encoded).attachments.sole
      expect(part.filename).to eq("fix.patch")
      expect(part.mime_type).to eq("text/x-diff")
      expect(part.decoded).to eq("diff\n")
    end

    it "changes the updated_at a PATCH is checked against" do
      get "/api/v1/drafts/#{draft.id}", headers: auth
      seen = body["updated_at"]

      upload_bytes("a")
      current = body["updated_at"]
      expect(current).not_to eq(seen)

      patch "/api/v1/drafts/#{draft.id}", params: { body: "x", updated_at: seen }.to_json, headers: json(auth)
      expect_error(:conflict, "conflict", /changed/)
      patch "/api/v1/drafts/#{draft.id}", params: { body: "x", updated_at: current }.to_json, headers: json(auth)
      expect(response).to have_http_status(:ok)
    end

    it "sees a new updated_at after an upload or a removal on the site as well" do
      sign_in_as(user)
      stream = { "Accept" => "text/vnd.turbo-stream.html" }
      file = Rack::Test::UploadedFile.new(StringIO.new("a"), "text/plain", true, original_filename: "a.txt")
      marked = draft.tap { |row| row.update_columns(last_edited_via_token_id: token.id) }.updated_at

      post draft_attachments_path(draft), params: { files: [ file ] }, headers: stream
      uploaded = draft.reload.updated_at
      expect(uploaded).to be > marked

      delete draft_attachment_path(draft, draft.draft_attachments.sole), headers: stream
      expect(draft.reload.updated_at).to be > uploaded
      expect(draft.last_edited_via_token).to eq(token)
    end

    it "takes Base64 with and without line breaks" do
      bytes = "\x00\xFFbinary".b * 50
      forms = [
        b64(bytes),
        Base64.encode64(bytes),
        Base64.encode64(bytes).gsub("\n", "\r\n"),
        " #{b64(bytes).scan(/.{1,76}/).join("\n\t ")} \n"
      ]

      forms.each do |content|
        upload({ file_name: "a.bin", content_base64: content })

        expect(response).to have_http_status(:created), content.first(90).inspect
      end
      expect(draft.draft_attachments.map(&:decoded_body)).to eq([ bytes ] * 4)
      expect(draft.draft_attachments.map(&:content_type).uniq).to eq([ "application/octet-stream" ])
    end

    it "refuses content that is not Base64, or empty" do
      cases = {
        "YQ" => /content_base64 is not valid Base64/,
        "YQ=" => /content_base64 is not valid Base64/,
        "YQ==YQ==" => /content_base64 is not valid Base64/,
        "a$b=" => /content_base64 is not valid Base64/,
        "-_-_" => /content_base64 is not valid Base64/,
        "data:text/plain;base64,YQ==" => /content_base64 is not valid Base64/,
        "YQ\u00a0==" => /content_base64 is not valid Base64/,
        "" => /content_base64 must not be blank/,
        " \n" => /content_base64 must not be blank/,
        nil => /content_base64 must be a string/,
        [ "YQ==" ] => /content_base64 must be a string/,
        5 => /content_base64 must be a string/
      }

      unchanged do
        cases.each do |content, message|
          upload({ file_name: "a.txt", content_base64: content })

          expect_error(:unprocessable_content, "invalid_body", message)
        end
      end
    end

    it "takes the file name without its path, and refuses one it cannot use" do
      { "dir/sub/fix.patch" => "fix.patch", "../../etc/passwd" => "passwd", "C:\\dir\\a.txt" => "C:_dir_a.txt",
        "a" * 255 => "a" * 255, "\u00e9" * 255 => "\u00e9" * 255, "fix\u202egpj.patch" => "fixgpj.patch",
        "a\u2028b.txt" => "ab.txt", ".." => "attachment", "." => "attachment" }.each do |given, stored|
        upload({ file_name: given, content_base64: "YQ==" })

        expect(response).to have_http_status(:created), given.first(40)
        expect(body["attachments"].last["file_name"]).to eq(stored)
      end

      cases = {
        { content_base64: "YQ==" } => /file_name is required/,
        { file_name: "", content_base64: "YQ==" } => /file_name must not be blank/,
        { file_name: " ", content_base64: "YQ==" } => /file_name must not be blank/,
        { file_name: nil, content_base64: "YQ==" } => /file_name must be a string/,
        { file_name: 5, content_base64: "YQ==" } => /file_name must be a string/,
        { file_name: "a\nb.txt", content_base64: "YQ==" } => /file_name must be a single line/,
        { file_name: "a\u0000b.txt", content_base64: "YQ==" } => /file_name has a NUL byte/,
        { file_name: "a" * 256, content_base64: "YQ==" } => /file_name is too long, at most 255 characters/,
        { file_name: "a.txt" } => /content_base64 is required/,
        { file_name: "a.txt", content_base64: "YQ==", content: "a" } => /unknown field: content/,
        { file_name: "a.txt", content_base64: "YQ==", byte_size: 1 } => /unknown field: byte_size/,
        { files: [ { file_name: "a.txt", content_base64: "YQ==" } ] } => /unknown field: files/,
        "[]" => /must be a JSON object/
      }
      unchanged do
        cases.each do |fields, message|
          upload(fields)

          expect_error(:unprocessable_content, "invalid_body", message)
        end
      end
    end

    it "takes a content type that looks like a media type and no other" do
      long = "a/#{'b' * 253}"
      good = {
        "text/x-diff" => "text/x-diff", "text/plain; charset=utf-8" => "text/plain; charset=utf-8",
        "application/vnd.api+json" => "application/vnd.api+json", "Text/Plain;charset=UTF-8" => "text/plain; charset=utf-8",
        "text/plain;charset=utf-8; name=\"fix.patch\"" => "text/plain; charset=utf-8", "text/plain; charset=koi8-r" => "text/plain",
        "text/x-diff; name=a.patch" => "text/x-diff", "multipart/mixed; boundary=x" => "application/octet-stream",
        "message/rfc822" => "application/octet-stream", long => Drafts::AttachmentAdder.content_type(long)
      }
      good.each do |type, stored|
        upload({ file_name: "a.txt", content_type: type, content_base64: "YQ==" })

        expect(response).to have_http_status(:created), type
        expect(body["attachments"].last["content_type"]).to eq(stored), type
        expect(draft.draft_attachments.order(:id).last.content_type).to eq(stored)
      end

      cases = {
        "text" => /content_type must be a media type/,
        "text/" => /content_type must be a media type/,
        "/plain" => /content_type must be a media type/,
        "text/x diff" => /content_type must be a media type/,
        "text/plain; charset" => /content_type must be a media type/,
        "text/plain, text/html" => /content_type must be a media type/,
        "text/plain; name=\"a\"b\"" => /content_type must be a media type/,
        "text/plain\r\nBcc: x@example.org" => /content_type must be a single line/,
        "a/#{'b' * 254}" => /content_type is too long, at most 255 characters/,
        "" => /content_type must not be blank/,
        nil => /content_type must be a string/,
        5 => /content_type must be a string/
      }
      unchanged do
        cases.each do |type, message|
          upload({ file_name: "a.txt", content_type: type, content_base64: "YQ==" })

          expect_error(:unprocessable_content, "invalid_body", message)
        end
      end
    end

    it "takes a total of exactly 2 MB and refuses one byte more, storing nothing" do
      upload_bytes("x" * (cap - 1), name: "big.bin")
      expect(response).to have_http_status(:created)
      upload_bytes("y", name: "one.bin")
      expect(response).to have_http_status(:created)
      expect(draft.attachment_bytes).to eq(2.megabytes)

      unchanged do
        upload_bytes("z", name: "over.bin")

        expect_error(:unprocessable_content, "invalid_body", /2097153 bytes.*limit.*2097152 bytes/)
      end

      fresh = draft_of(user)
      upload_bytes("x" * cap, to: fresh)
      expect(response).to have_http_status(:created)
      fresh.draft_attachments.delete_all
      unchanged(fresh) do
        upload_bytes("x" * (cap + 1), to: fresh)

        expect_error(:unprocessable_content, "invalid_body", /limit/)
      end
    end

    it "refuses a draft that is being sent with a conflict, and a sent one" do
      set_state(draft, "sending")
      unchanged { upload_bytes("a") }
      expect_error(:conflict, "conflict", /being sent/)

      set_state(draft, "sent")
      unchanged { upload_bytes("a") }
      expect_error(:unprocessable_content, "invalid_body", /sent/)
    end

    it "does not store on the draft of another user, or on one that does not exist" do
      foreign = draft_of(other)

      unchanged(foreign) do
        upload_bytes("a", to: foreign)
        expect_error(:not_found, "not_found")

        upload("[]", to: foreign)
        expect_error(:not_found, "not_found")
      end

      upload_bytes("a", to: foreign, headers: other_auth)
      expect(response).to have_http_status(:created)
      expect(body["attachments"].size).to eq(1)

      [ foreign.id + 1000, "9" * 30, "abc" ].each do |id|
        post "/api/v1/drafts/#{id}/attachments", params: { file_name: "a", content_base64: "YQ==" }.to_json, headers: json(auth)
        expect_error(:not_found, "not_found")
      end
      expect(draft.draft_attachments.count).to eq(0)
    end

    it "needs a token" do
      unchanged do
        upload_bytes("a", headers: {})
        expect_error(:unauthorized, "token_required")
        expect(response.headers["WWW-Authenticate"]).to eq("Bearer")

        token.revoke!
        upload_bytes("a")
        expect_error(:unauthorized, "invalid_token")
      end
    end

    it "takes JSON only, and nothing from the query string" do
      fields = { file_name: "a.txt", content_base64: "YQ==" }

      unchanged do
        post files_path, params: fields, headers: auth
        expect_error(:unsupported_media_type, "unsupported_media_type")

        file = Rack::Test::UploadedFile.new(StringIO.new("a"), "text/plain", true, original_filename: "a.txt")
        post files_path, params: { files: [ file ] }, headers: auth
        expect_error(:unsupported_media_type, "unsupported_media_type")

        post "#{files_path}?file_name=a.txt", params: fields.to_json, headers: json(auth)
        expect_error(:bad_request, "invalid_parameter", /file_name/)
      end
    end

    it "keeps nothing of a request that ends in an error" do
      allow_any_instance_of(Api::V1::DraftSerializer).to receive(:full).and_raise(ActiveRecord::RecordNotFound)

      unchanged { upload_bytes("a") }

      expect_error(:not_found, "not_found")
    end
  end

  describe "DELETE /drafts/{id}/attachments/{attachment_id}" do
    let!(:attachment) { create(:draft_attachment, outgoing_draft: draft, file_name: "a.patch") }
    let!(:kept) { create(:draft_attachment, outgoing_draft: draft, file_name: "b.patch", content: "bb") }

    it "removes the file and gives the draft without it" do
      was = draft.updated_at

      remove(attachment)

      expect(response).to have_http_status(:ok)
      expect(body.keys).to eq(detail_keys)
      expect(body["attachments"]).to eq([ { "id" => kept.id, "file_name" => "b.patch", "content_type" => "text/x-diff", "byte_size" => 2 } ])
      expect(body["last_edited_via"]).to eq("token_name" => "agent")
      expect(DraftAttachment.exists?(attachment.id)).to be(false)
      expect(draft.reload.updated_at).to be > was
      expect(draft.last_edited_via_token).to eq(token)
      expect(body["updated_at"]).to eq(draft.updated_at.as_json)

      unchanged { remove(attachment) }
      expect_error(:not_found, "not_found")
    end

    it "makes room for another file" do
      full = create(:draft_attachment, outgoing_draft: draft, content: "x", byte_size: cap - 3)
      upload_bytes("a")
      expect_error(:unprocessable_content, "invalid_body", /limit/)

      remove(full)
      upload_bytes("a")
      expect(response).to have_http_status(:created)
    end

    it "does not find an attachment that is not on that draft" do
      second = draft_of(user)
      on_second = create(:draft_attachment, outgoing_draft: second)
      foreign = draft_of(other)
      on_foreign = create(:draft_attachment, outgoing_draft: foreign)

      unchanged(draft, second, foreign) do
        [ [ on_second, draft ], [ on_foreign, draft ], [ on_foreign, foreign ], [ attachment, second ], [ attachment, foreign ] ].each do |file, from|
          remove(file, from: from)

          expect_error(:not_found, "not_found")
        end
        [ kept.id + 1000, "9" * 30, "abc" ].each do |id|
          delete "#{files_path}/#{id}", headers: auth
          expect_error(:not_found, "not_found")
        end
      end

      remove(on_foreign, from: foreign, headers: other_auth)
      expect(response).to have_http_status(:ok)
      expect(body["attachments"]).to eq([])
    end

    it "refuses a draft that is being sent with a conflict, and a sent one" do
      set_state(draft, "sending")
      unchanged { remove(attachment) }
      expect_error(:conflict, "conflict", /being sent/)

      set_state(draft, "sent")
      unchanged { remove(attachment) }
      expect_error(:unprocessable_content, "unprocessable_content", /sent/)
    end

    it "needs a token, and takes no parameters" do
      unchanged do
        remove(attachment, headers: {})
        expect_error(:unauthorized, "token_required")

        delete "#{files_path}/#{attachment.id}?force=true", headers: auth
        expect_error(:bad_request, "invalid_parameter")

        token.revoke!
        remove(attachment)
        expect_error(:unauthorized, "invalid_token")
      end
    end
  end

  describe "the size of a request" do
    let(:limit) { Api::RequestBody::MAX_BYTES }
    let(:big) { { file_name: "a.bin", content_base64: "A" * 5.megabytes }.to_json }

    def padded(bytes)
      empty = { file_name: "a.bin", content_base64: "" }.to_json
      filler = bytes - empty.bytesize - 3.megabytes
      { file_name: "a.bin", content_base64: "A" * 3.megabytes + " " * filler }.to_json
    end

    def each_operation(content, headers = json(auth))
      yield -> { post files_path, params: content, headers: headers }
      yield -> { post "/api/v1/drafts", params: content, headers: headers }
      yield -> { patch "/api/v1/drafts/#{draft.id}", params: content, headers: headers }
      yield -> { delete "/api/v1/drafts/#{draft.id}", params: content, headers: headers }
      yield -> { delete "#{files_path}/1", params: content, headers: headers }
    end

    it "parses the body of a request within the limit" do
      expect(ActiveSupport::JSON).to receive(:decode).at_least(:once).and_call_original

      upload_bytes("a")

      expect(response).to have_http_status(:created)
    end

    it "refuses a body over 4 MB and never parses it" do
      expect(limit).to eq(4.megabytes)
      expect(ActiveSupport::JSON).not_to receive(:decode)
      codes = []

      before = draft.reload.attributes
      each_operation(big) do |request|
        request.call
        codes << [ response.status, response.media_type, response.body ]
      end
      each_operation(big, json({})) do |request|
        request.call
        codes << [ response.status, response.media_type, response.body ]
      end

      expect(codes.map(&:first).uniq).to eq([ 413 ])
      expect(codes.map(&:second).uniq).to eq([ "application/json" ])
      expect(codes.map { |row| JSON.parse(row.last).dig("error", "code") }.uniq).to eq([ "payload_too_large" ])
      expect(JSON.parse(codes.first.last).dig("error", "message")).to match(/4 MB/)
      expect(draft.reload.attributes).to eq(before)
      expect(DraftAttachment.count).to eq(0)
    end

    it "draws the line at the byte" do
      upload(padded(limit))
      expect_error(:unprocessable_content, "invalid_body", /limit/)

      upload(padded(limit + 1))
      expect_error(413, "payload_too_large")
    end

    it "does not believe the Content-Length of a body sent in chunks" do
      chunked = json(auth).merge("Transfer-Encoding" => "chunked", "CONTENT_LENGTH" => "10")

      post files_path, params: { file_name: "a.txt", content_base64: "YQ==" }.to_json, headers: chunked
      expect(response).to have_http_status(:created)
      expect(draft.draft_attachments.sole.decoded_body).to eq("a")

      post files_path, params: padded(limit), headers: chunked
      expect_error(:unprocessable_content, "invalid_body", /limit/)

      expect(ActiveSupport::JSON).not_to receive(:decode)
      unchanged { post files_path, params: big, headers: chunked }
      expect(response).to have_http_status(413)
      expect(response.body).to include("payload_too_large")
    end

    it "leaves room for a file of 2 MB in line-wrapped Base64" do
      upload({ file_name: "big.bin", content_base64: Base64.encode64(Random.bytes(cap)).gsub("\n", "\r\n") })

      expect(response).to have_http_status(:created)
      expect(draft.attachment_bytes).to eq(cap)
    end
  end

  describe "the document" do
    let(:document) { OpenapiHelper.contract.document }
    let(:schema) { OpenapiHelper.contract.request_body_schema("/drafts/{id}/attachments", "post") }

    it "has the limits of the code" do
      expect(schema.dig("properties", "content_type", "pattern")).to eq(Api::V1::DraftAttachmentsController::MEDIA_TYPE)
      expect(schema.dig("properties", "content_base64", "description")).to include("2 MB")
      expect(document.dig("info", "description")).to include("2 MB", "4 MB")
      expect(ActiveSupport::NumberHelper.number_to_human_size(cap)).to eq("2 MB")
      expect(ActiveSupport::NumberHelper.number_to_human_size(Api::RequestBody::MAX_BYTES)).to eq("4 MB")
    end

    it "documents the 413 on every operation with a body" do
      document["paths"].each do |template, item|
        item.slice("post", "put", "patch").each do |verb, operation|
          expect(operation.dig("responses", "413")).to eq("$ref" => "#/components/responses/PayloadTooLarge"), "#{verb} #{template}"
        end
      end
    end
  end

  describe "the limit on the attachments of a user" do
    let(:limit) { Drafts::TokenLimits::ATTACHMENT_BYTES }

    def stored(bytes, on: draft_of(user))
      create(:draft_attachment, outgoing_draft: on, content: "x", byte_size: bytes)
    end

    it "takes a total of exactly 20 MB over the drafts that are not sent, and refuses one byte more" do
      expect(limit).to eq(20.megabytes)
      9.times { stored(cap) }
      stored(cap - 1)

      upload_bytes("a")
      expect(response).to have_http_status(:created)

      unchanged do
        upload_bytes("b")

        expect_error(:unprocessable_content, "draft_limit", /20971520 bytes.*send or delete/)
      end
    end

    it "does not count sent drafts, or the drafts of others" do
      10.times { stored(cap, on: draft_of(user).tap { |sent| set_state(sent, "sent") }) }
      10.times { stored(cap, on: draft_of(other)) }
      9.times { stored(cap) }

      upload_bytes("a")

      expect(response).to have_http_status(:created)
    end

    it "makes room when a file is removed" do
      first = stored(cap)
      9.times { stored(cap) }
      upload_bytes("a")
      expect_error(:unprocessable_content, "draft_limit")

      remove(first, from: first.outgoing_draft)
      expect(response).to have_http_status(:ok)
      upload_bytes("a")
      expect(response).to have_http_status(:created)
    end

    it "says that a sent draft is sent, at the limit too" do
      10.times { stored(cap) }
      set_state(draft, "sent")

      upload_bytes("a")

      expect_error(:unprocessable_content, "invalid_body", /sent/)
    end

    it "does not limit an upload on the site" do
      10.times { stored(cap) }

      result = Drafts::AttachmentAdder.call(draft: draft, files: [ { name: "a.txt", content_type: "text/plain", bytes: "a" } ])

      expect(result).to be_added
    end
  end

  describe "a Content-Length that is no length" do
    let(:content) { { file_name: "a.txt", content_base64: "YQ==" }.to_json }

    it "is not believed: the body is read as far as the limit" do
      [ "-1", "abc", "", "1e3", "12 " ].each do |length|
        DraftAttachment.where(outgoing_draft_id: draft.id).delete_all

        post files_path, params: content, headers: json(auth).merge("CONTENT_LENGTH" => length)

        expect(response).to have_http_status(:created), "#{length.inspect} gave #{response.status}: #{response.body.first(200)}"
        expect(draft.draft_attachments.reload.map(&:decoded_body)).to eq([ "a" ]), length.inspect
      end
    end

    it "does not hide a body over the limit" do
      big = { file_name: "a.bin", content_base64: "A" * 5.megabytes }.to_json
      expect(ActiveSupport::JSON).not_to receive(:decode)

      [ "-1", "abc" ].each do |length|
        unchanged { post files_path, params: big, headers: json(auth).merge("CONTENT_LENGTH" => length) }

        expect_error(413, "payload_too_large")
      end
    end

    it "answers a request without a body as usual" do
      [ "-1", "abc" ].each do |length|
        get "/api/v1/drafts/#{draft.id}", headers: auth.merge("CONTENT_LENGTH" => length)
        expect(response).to have_http_status(:ok)

        get "/api/v1/mailing_lists", headers: { "CONTENT_LENGTH" => length }
        expect(response).to have_http_status(:ok)

        get "/api/v1/nope", headers: { "CONTENT_LENGTH" => length }
        expect(response).to have_http_status(:not_found)
        expect(response.media_type).to eq("application/json")
      end
    end
  end
end
