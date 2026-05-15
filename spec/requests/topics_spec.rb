require 'rails_helper'

RSpec.describe "Topics", type: :request do
  def sign_in(email:, password: 'secret')
    post session_path, params: { email: email, password: password }
    expect(response).to redirect_to(root_path)
  end

  def attach_verified_alias(user, email:, primary: true)
    al = create(:alias, user: user, email: email)
    if primary && user.person&.default_alias_id.nil?
      user.person.update!(default_alias_id: al.id)
    end
    Alias.by_email(email).update_all(verified_at: Time.current)
    al
  end

  describe "GET /topics" do
    context "when there are topics with messages" do
      let!(:creator1) { create(:alias) }
      let!(:creator2) { create(:alias) }
      let!(:topic1) { create(:topic, creator: creator1, created_at: 2.days.ago) }
      let!(:topic2) { create(:topic, creator: creator2, created_at: 1.day.ago) }
      let!(:message1) { create(:message, topic: topic1, sender: creator1, created_at: 2.days.ago) }
      let!(:message2) { create(:message, topic: topic2, sender: creator2, created_at: 1.day.ago) }

      it "returns http success" do
        get topics_path
        expect(response).to have_http_status(:success)
      end

      it "renders the index page" do
        get topics_path
        expect(response.body).to include("PostgreSQL Hackers Archive")
      end

      it "displays topic titles" do
        get topics_path
        expect(response.body).to include(topic1.title)
        expect(response.body).to include(topic2.title)
      end

      it "shows topics with most recent activity first" do
        get topics_path
        topic1_position = response.body.index(topic1.title)
        topic2_position = response.body.index(topic2.title)
        expect(topic2_position).to be < topic1_position
      end

      it "displays creator names" do
        get topics_path
        expect(response.body).to include(creator1.name)
        expect(response.body).to include(creator2.name)
      end
    end

    context "when there are no topics" do
      it "returns http success with empty state" do
        get topics_path
        expect(response).to have_http_status(:success)
        expect(response.body).to include("topics-table")
      end
    end
  end

  describe "GET /topics/:id" do
    let!(:creator) { create(:alias) }
    let!(:topic) { create(:topic, creator: creator) }
    let!(:root_message) { create(:message, topic: topic, sender: creator, reply_to: nil, created_at: 2.hours.ago) }
    let!(:reply_message) { create(:message, topic: topic, sender: creator, reply_to: root_message, created_at: 1.hour.ago) }

    context "with default parameters" do
      it "returns http success" do
        get topic_path(topic)
        expect(response).to have_http_status(:success)
      end

      it "displays the topic title" do
        get topic_path(topic)
        expect(response.body).to include(topic.title)
      end

      it "displays messages" do
        get topic_path(topic)
        expect(response.body).to include(root_message.body)
        expect(response.body).to include(reply_message.body)
      end

      it "shows flat view (oldest first)" do
        get topic_path(topic)
        expect(response.body).to include('messages-container flat')
        root_position = response.body.index(root_message.body)
        reply_position = response.body.index(reply_message.body)
        expect(root_position).to be < reply_position
      end

      it "renders patch attachments with lazy-loaded content" do
        attachment = create(:attachment, :patch_file, message: root_message)

        get topic_path(topic)

        expect(response).to have_http_status(:success)
        expect(response.body).to include("Attachments:")
        expect(response.body).to include("attachment-content-#{attachment.id}")
        expect(response.body).not_to include("diff --git")
      end
    end

    context "with signed-in user and read/unread messages" do
      let!(:user) { create(:user, password: "secret", password_confirmation: "secret") }

      before do
        attach_verified_alias(user, email: "reader@example.com")
        sign_in(email: "reader@example.com")
      end

      it "renders read messages as shells with skeleton placeholder" do
        MessageReadRange.add_range(user: user, topic: topic, start_id: root_message.id, end_id: root_message.id)

        get topic_path(topic)
        expect(response).to have_http_status(:success)

        # Read message should have skeleton placeholder, not inline body
        expect(response.body).to include("message-batch-skeleton")
        expect(response.body).not_to include(root_message.body)

        # Unread message should be rendered inline
        expect(response.body).to include(reply_message.body)
      end

      it "renders first 20 unread messages inline and rest as shells" do
        messages = (1..25).map do |i|
          create(:message, topic: topic, sender: creator, created_at: i.hours.ago, body: "Unread message body #{i}")
        end

        get topic_path(topic)
        expect(response).to have_http_status(:success)

        # First 20 unread messages rendered inline (root_message and reply_message are also unread, so they count)
        # Total unread = root_message + reply_message + 25 created = 27
        # First 20 get inline, remaining 7 get shells
        inline_count = response.body.scan("message-content message-content").size
        skeleton_count = response.body.scan("message-batch-skeleton").size
        expect(inline_count).to eq(20)
        expect(skeleton_count).to eq(7)
      end
    end

    context "with nonexistent topic" do
      it "returns 404" do
        get topic_path(id: 99999)
        expect(response).to have_http_status(:not_found)
      end
    end

    context "with a signed-in user who has a sent draft for a message" do
      let!(:user) { create(:user, password: "secret", password_confirmation: "secret") }
      let!(:user_alias) { attach_verified_alias(user, email: "composer@example.com") }
      let!(:identity) {
        create(:identity, user: user, email: "composer@example.com",
               refresh_token: "r", send_authorized_at: 1.hour.ago)
      }
      let!(:sent_msg) {
        create(:message, topic: topic, sender: user_alias, sender_person_id: user_alias.person_id,
               reply_to: root_message, subject: "Re: parent", body: "reply body")
      }
      let!(:sent_draft) {
        create(:outgoing_draft,
               user: user, topic: topic, reply_to_message: root_message,
               identity: identity, sender_alias: user_alias,
               status: "sent", sent_message_id: sent_msg.id, sent_at: 1.minute.ago)
      }

      before { sign_in(email: "composer@example.com") }

      it "does not render the reply-composer for a sent draft" do
        get topic_path(topic)
        expect(response).to have_http_status(:success)
        expect(response.body).not_to include(%(data-reply-composer-draft-id-value="#{sent_draft.id}"))
      end

      it "still renders the composer for an active draft on a different parent" do
        active_draft = create(:outgoing_draft,
                              user: user, topic: topic, reply_to_message: reply_message,
                              identity: identity, sender_alias: user_alias)
        get topic_path(topic)
        expect(response).to have_http_status(:success)
        expect(response.body).to include(%(data-reply-composer-draft-id-value="#{active_draft.id}"))
        expect(response.body).not_to include(%(data-reply-composer-draft-id-value="#{sent_draft.id}"))
      end
    end

    context "with a signed-in user whose send is unauthorized but who has an active draft" do
      let!(:user) { create(:user, password: "secret", password_confirmation: "secret") }
      let!(:user_alias) { attach_verified_alias(user, email: "composer@example.com") }
      # refresh_token nil + send_revoked_at set => NOT send_authorized => can_send_email? false
      let!(:identity) {
        create(:identity, user: user, email: "composer@example.com",
               refresh_token: nil, send_revoked_at: 1.minute.ago)
      }
      let!(:active_draft) {
        create(:outgoing_draft,
               user: user, topic: topic, reply_to_message: root_message,
               identity: identity, sender_alias: user_alias,
               status: "idle", last_send_error: "Authorization revoked: prior failure")
      }

      before { sign_in(email: "composer@example.com") }

      it "still renders the composer for the active draft" do
        get topic_path(topic)
        expect(response).to have_http_status(:success)
        expect(response.body).to include(%(data-reply-composer-draft-id-value="#{active_draft.id}"))
      end

      it "does not render a new-reply button on a message that has no draft" do
        get topic_path(topic)
        expect(response.body).not_to include(%(name="reply_to_message_id" value="#{reply_message.id}"))
      end
    end
  end

  describe "GET /attachments/:id" do
    let!(:creator) { create(:alias) }
    let!(:topic) { create(:topic, creator: creator) }
    let!(:message) { create(:message, topic: topic, sender: creator, reply_to: nil, created_at: 2.hours.ago) }

    it "streams the attachment as a download with the right filename" do
      attachment = create(:attachment, :patch_file, message: message)

      get attachment_path(attachment)

      expect(response).to have_http_status(:success)
      expect(response.headers["Content-Disposition"]).to include("attachment")
      expect(response.headers["Content-Disposition"]).to include(attachment.file_name)
      expect(response.body).to include("diff --git")
    end

    it "returns 404 when the attachment body is missing" do
      attachment = create(:attachment, body: nil, message: message)

      get attachment_path(attachment)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /topics/search" do
    let!(:creator1) { create(:alias) }
    let!(:creator2) { create(:alias) }
    let!(:topic1) { create(:topic, title: "PostgreSQL Performance Tuning", creator: creator1) }
    let!(:topic2) { create(:topic, title: "MySQL vs PostgreSQL", creator: creator2) }
    let!(:message1) { create(:message, topic: topic1, body: "Performance optimization tips", sender: creator1) }
    let!(:message2) { create(:message, topic: topic2, body: "Database comparison", sender: creator2) }

    context "with search query" do
      it "returns http success" do
        get search_topics_path, params: { q: "PostgreSQL" }
        expect(response).to have_http_status(:success)
      end

      it "displays search results" do
        get search_topics_path, params: { q: "Performance" }
        expect(response.body).to include(topic1.title)
        expect(response.body).not_to include(topic2.title)
      end

      it "shows the search query" do
        get search_topics_path, params: { q: "PostgreSQL" }
        expect(response.body).to include('value="PostgreSQL"')
      end

      it "finds topics by message content" do
        get search_topics_path, params: { q: "optimization" }
        expect(response.body).to include(topic1.title)
      end
    end

    context "without search query" do
      it "shows search form" do
        get search_topics_path
        expect(response).to redirect_to(topics_path(anchor: "search"))
      end
    end

    context "with empty search query" do
      it "shows search form" do
        get search_topics_path, params: { q: "   " }
        expect(response).to redirect_to(topics_path(anchor: "search"))
      end
    end

    context "with no results" do
      it "shows no results message" do
        get search_topics_path, params: { q: "nonexistent" }
        expect(response.body).to include("No results found")
      end
    end

    context "with search query and no saved search (signed in)" do
      let!(:search_user) { create(:user, password: "secret", password_confirmation: "secret") }

      before do
        attach_verified_alias(search_user, email: "searcher@example.com")
      end

      it "shows save this search option" do
        sign_in(email: "searcher@example.com")
        get search_topics_path, params: { q: "PostgreSQL" }
        expect(response.body).to include("Save this search")
      end
    end

    context "with saved_search_id" do
      let!(:saved_search) { create(:saved_search, name: "My Search", query: "PostgreSQL", scope: "global") }

      it "loads search results from saved search" do
        get search_topics_path, params: { saved_search_id: saved_search.id }
        expect(response).to have_http_status(:success)
        expect(response.body).to include(topic1.title)
      end

      it "shows the saved search name" do
        get search_topics_path, params: { saved_search_id: saved_search.id }
        expect(response.body).to include("My Search")
      end

      it "ignores q param when saved_search_id is present" do
        get search_topics_path, params: { saved_search_id: saved_search.id, q: "nonexistent" }
        expect(response.body).to include(topic1.title)
      end

      it "returns 404 for non-existent saved search" do
        get search_topics_path, params: { saved_search_id: 999999 }
        expect(response).to have_http_status(:not_found)
      end
    end

    context "with saved_search_id and team_id" do
      let!(:team) { create(:team, name: "CoreTeam") }
      let!(:team_user) { create(:user, password: "secret", password_confirmation: "secret") }
      let!(:team_template) { create(:saved_search, name: "Team Posts", query: "{{team_name}}", scope: "team") }
      let!(:matching_topic) { create(:topic, title: "CoreTeam discussion", creator: creator1) }
      let!(:matching_message) { create(:message, topic: matching_topic, body: "CoreTeam content", sender: creator1) }

      before do
        create(:team_member, team: team, user: team_user, role: "member")
        attach_verified_alias(team_user, email: "teamuser@example.com")
      end

      it "resolves team template query and returns matching results" do
        sign_in(email: "teamuser@example.com")
        get search_topics_path, params: { saved_search_id: team_template.id, team_id: team.id }
        expect(response).to have_http_status(:success)
        expect(response.body).to include("CoreTeam discussion")
      end
    end

    context "sidebar saved search links" do
      let!(:saved_search) { create(:saved_search, name: "Global Search", query: "has:patch", scope: "global") }

      it "links saved searches by id" do
        get search_topics_path, params: { q: "PostgreSQL" }
        expect(response.body).to include("saved_search_id=#{saved_search.id}")
      end

      it "highlights active saved search by id" do
        get search_topics_path, params: { saved_search_id: saved_search.id }
        expect(response.body).to include("is-active")
      end
    end

    context "with user-scoped saved search belonging to another user" do
      let!(:owner) { create(:user, password: "secret", password_confirmation: "secret") }
      let!(:other_user) { create(:user, password: "secret", password_confirmation: "secret") }
      let!(:private_search) { create(:saved_search, name: "Private", query: "PostgreSQL", scope: "user", user: owner) }

      before do
        attach_verified_alias(other_user, email: "other@example.com")
      end

      it "returns 404 when accessing another user's saved search" do
        sign_in(email: "other@example.com")
        get search_topics_path, params: { saved_search_id: private_search.id }
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "GET /topics/:id/latest_patchset" do
    let!(:creator) { create(:alias) }
    let!(:topic) { create(:topic, creator: creator) }

    context "with patches in topic" do
      let!(:old_message) { create(:message, topic: topic, sender: creator, created_at: 1.day.ago) }
      let!(:old_patch) { create(:attachment, :patch_file, message: old_message, file_name: "old.patch") }

      let!(:latest_message) { create(:message, topic: topic, sender: creator, created_at: 1.hour.ago) }
      let!(:patch1) { create(:attachment, :patch_file, message: latest_message, file_name: "0001-foo.patch") }
      let!(:patch2) { create(:attachment, :patch_file, message: latest_message, file_name: "0002-bar.patch") }

      it "returns patchset from latest message as tar.gz" do
        get latest_patchset_topic_path(topic)

        expect(response).to have_http_status(:ok)
        expect(response.content_type).to eq("application/gzip")
        expect(response.headers["Content-Disposition"]).to include("attachment")
        expect(response.headers["Content-Disposition"]).to include("topic-#{topic.id}-patchset.tar.gz")
      end

      it "includes all patches from latest message" do
        get latest_patchset_topic_path(topic)

        # Extract and verify tar.gz contents
        require 'zlib'
        require 'rubygems/package'

        io = StringIO.new(response.body)
        extracted_files = {}
        Zlib::GzipReader.wrap(io) do |gz|
          Gem::Package::TarReader.new(gz) do |tar|
            tar.each do |entry|
              extracted_files[entry.full_name] = entry.read
            end
          end
        end

        # Should include both patches from latest message
        expect(extracted_files).to have_key("0001-foo.patch")
        expect(extracted_files).to have_key("0002-bar.patch")
        expect(extracted_files["0001-foo.patch"]).to eq(patch1.decoded_body_utf8)
        expect(extracted_files["0002-bar.patch"]).to eq(patch2.decoded_body_utf8)

        # Should NOT include old patch
        expect(extracted_files.keys).not_to include("old.patch")
      end
    end

    context "without patches" do
      let!(:message) { create(:message, topic: topic, sender: creator) }

      it "returns 404" do
        get latest_patchset_topic_path(topic)
        expect(response).to have_http_status(:not_found)
      end
    end

    context "with non-patch attachments only" do
      let!(:message) { create(:message, topic: topic, sender: creator) }
      let!(:attachment) { create(:attachment, message: message, file_name: "document.pdf") }

      it "returns 404" do
        get latest_patchset_topic_path(topic)
        expect(response).to have_http_status(:not_found)
      end
    end

    context "with content-based patches only (no .diff or .patch extension)" do
      let!(:message) { create(:message, topic: topic, sender: creator) }
      let!(:attachment) { create(:attachment, :content_based_patch, message: message) }

      it "returns 404" do
        get latest_patchset_topic_path(topic)
        expect(response).to have_http_status(:not_found)
      end
    end

    context "with nonexistent topic" do
      it "returns 404" do
        get latest_patchset_topic_path(id: 99999)
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "GET /messages/:id/content" do
    let!(:creator) { create(:alias) }
    let!(:topic) { create(:topic, creator: creator) }
    let!(:message) { create(:message, topic: topic, sender: creator) }

    it "returns message body in a turbo frame" do
      get message_content_path(message)
      expect(response).to have_http_status(:success)
      expect(response.body).to include("message-body-#{message.id}")
      expect(response.body).to include(message.body)
    end
  end
end

RSpec.describe 'Topics show — drafts sidebar', type: :request do
  let(:user)     { create(:user) }
  let!(:identity){ create(:identity, user: user, email: 'a@b', refresh_token: 'r', send_authorized_at: 1.hour.ago) }
  let!(:sender)  { create(:alias, user: user, email: 'a@b', name: 'Alice') }
  let(:list)     { create(:mailing_list, post_address: 'real@list.example') }
  let(:topic)    { create(:topic, mailing_lists: [list]) }
  let!(:parent)  { create(:message, topic: topic, subject: 'Hi') }

  before { sign_in_as(user) }

  it 'renders no Drafts heading when no drafts exist' do
    get topic_path(topic)
    expect(response.body).not_to include('drafts-list')
  end

  it 'renders Drafts section with the message number when a draft exists' do
    create(:outgoing_draft, user: user, topic: topic,
           reply_to_message: parent, identity: identity, sender_alias: sender)
    get topic_path(topic)
    html = Nokogiri::HTML(response.body)
    list  = html.css('ul.drafts-list')
    expect(list).not_to be_empty
    items = list.css('li .drafts-link')
    expect(items.size).to eq(1)
    expect(items.first.css('.drafts-target').text.strip).to eq('#1')
  end
end
