require "rails_helper"

RSpec.describe "API v1 drafts, a row lock held elsewhere", type: :request do
  self.use_transactional_tests = false

  let(:created) { {} }

  around do |example|
    settings = Rails.configuration.x
    saved = settings.api_statement_timeout_ms
    settings.api_statement_timeout_ms = 3000
    example.run
  ensure
    settings.api_statement_timeout_ms = saved
    clean_up
  end

  before { stub_const("Api::V1::BaseController::LOCK_TIMEOUT_MS", 200) }

  def row_counts
    connection = ActiveRecord::Base.lease_connection
    connection.tables.to_h { |table| [ table, connection.select_value("SELECT count(*) FROM #{connection.quote_table_name(table)}") ] }
  end

  def setup_rows
    created[:counts] = row_counts
    user = create(:user)
    identity = create(:identity, user: user, email: "lock-#{user.id}@example.org", refresh_token: "r", send_authorized_at: 1.hour.ago)
    sender = create(:alias, user: user, email: identity.email)
    topic = create(:topic)
    message = create(:message, topic: topic)
    draft = create(:outgoing_draft, user: user, topic: topic, reply_to_message: message, identity: identity, sender_alias: sender,
                                    subject: "Re: kept", body: "kept")
    attachment = create(:draft_attachment, outgoing_draft: draft)
    token, secret = ApiToken.issue!(user: user, name: "agent")
    created.merge!(user: user, identity: identity, sender: sender, topic: topic, message: message, draft: draft,
                   attachment: attachment, token: token)
    secret
  end

  # by id, children first: nothing here runs in a transaction that is rolled back
  def clean_up
    draft = created[:draft]
    return unless draft

    aliases = Alias.where(id: [ created[:sender].id, created[:topic].creator_id, created[:message].sender_id ])
    people = [ created[:user].person_id, *aliases.pluck(:person_id) ].compact.uniq
    DraftAttachment.where(outgoing_draft_id: draft.id).delete_all
    OutgoingDraft.where(id: draft.id).delete_all
    ApiToken.where(id: created[:token].id).delete_all
    TopicParticipant.where(topic_id: created[:topic].id).delete_all
    Topic.where(id: created[:topic].id).update_all(last_message_id: nil)
    Message.where(id: created[:message].id).delete_all
    Topic.where(id: created[:topic].id).delete_all
    Identity.where(id: created[:identity].id).delete_all
    Person.where(id: people).update_all(default_alias_id: nil)
    aliases.delete_all
    User.where(id: created[:user].id).delete_all
    Person.where(id: people).delete_all
    expect(row_counts).to eq(created[:counts])
  end

  # the row lock of another session, as a send on the site takes it
  def while_locked(draft)
    locked = Queue.new
    release = Queue.new
    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.transaction do
          connection.execute("SELECT id FROM outgoing_drafts WHERE id = #{Integer(draft.id)} FOR UPDATE")
          locked << true
          release.pop
        end
      end
    end
    locked.pop
    yield
  ensure
    release << true
    holder.join
  end

  def expect_busy
    expect(response).to have_http_status(:conflict)
    expect(response.media_type).to eq("application/json")
    error = JSON.parse(response.body).fetch("error")
    expect(error["code"]).to eq("conflict")
    expect(error["message"]).to match(/draft is busy, try again/)
  end

  it "answers the write actions with a conflict, keeps the draft, and leaves the session as it was" do
    secret = setup_rows
    draft = created[:draft]
    headers = { "Authorization" => "Bearer #{secret}", "Content-Type" => "application/json" }
    path = "/api/v1/drafts/#{draft.id}"
    connection = ActiveRecord::Base.lease_connection
    default = connection.select_value("SHOW lock_timeout")
    before = draft.reload.attributes

    while_locked(draft) do
      patch path, params: { body: "changed" }.to_json, headers: headers
      expect_busy

      post "#{path}/attachments", params: { file_name: "a.txt", content_base64: "YQ==" }.to_json, headers: headers
      expect_busy

      delete "#{path}/attachments/#{created[:attachment].id}", headers: headers
      expect_busy

      delete path, headers: headers
      expect_busy

      get path, headers: headers
      expect(response).to have_http_status(:ok)
    end

    expect(draft.reload.attributes).to eq(before)
    expect(draft.draft_attachments.pluck(:id)).to eq([ created[:attachment].id ])
    expect(connection.select_value("SHOW lock_timeout")).to eq(default)

    patch path, params: { body: "changed" }.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    expect(draft.reload.body).to eq("changed")
  end

  it "still answers a statement over its own limit with query_too_expensive" do
    secret = setup_rows
    Rails.configuration.x.api_statement_timeout_ms = 100
    stub_const("Api::V1::BaseController::LOCK_TIMEOUT_MS", 5000)

    while_locked(created[:draft]) do
      patch "/api/v1/drafts/#{created[:draft].id}", params: { body: "changed" }.to_json,
                                                   headers: { "Authorization" => "Bearer #{secret}", "Content-Type" => "application/json" }
    end

    expect(response).to have_http_status(:bad_request)
    expect(JSON.parse(response.body).dig("error", "code")).to eq("query_too_expensive")
  end
end
