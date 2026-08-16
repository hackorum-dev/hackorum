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

      context "with viewing_since holding the list steady" do
        it "keeps a topic at its snapshot position after it receives a newer message" do
          viewing_since = 12.hours.ago

          # topic1's newest message as of viewing_since is 2 days old, so it stays
          # below topic2 even though the new message makes it the latest overall.
          create(:message, topic: topic1, sender: creator1, created_at: 1.hour.ago)

          get topics_path, params: { viewing_since: viewing_since.iso8601 }

          expect(response).to have_http_status(:success)
          expect(response.body.index(topic2.title)).to be < response.body.index(topic1.title)
        end

        it "excludes topics whose only messages are newer than viewing_since" do
          future_topic = create(:topic, creator: creator1, created_at: 1.hour.ago)
          create(:message, topic: future_topic, sender: creator1, created_at: 30.minutes.ago)

          get topics_path, params: { viewing_since: 12.hours.ago.iso8601 }

          expect(response.body).not_to include(future_topic.title)
          expect(response.body).to include(topic1.title)
        end

        it "omits topics that have no messages at all" do
          empty_topic = create(:topic, creator: creator1, created_at: 3.days.ago)

          get topics_path

          expect(response.body).not_to include(empty_topic.title)
        end
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

    context "when there is a full page of topics" do
      let!(:creator) { create(:alias) }

      before do
        25.times do |i|
          topic = create(:topic, creator: creator, created_at: (i + 1).days.ago)
          create(:message, topic: topic, sender: creator, created_at: (i + 1).days.ago)
        end
      end

      it "marks the pagination frame for prefetching" do
        get topics_path
        expect(response.body).to include('data-controller="prefetch-frame"')
      end

      it "marks the replaced pagination frame for prefetching" do
        get topics_path(format: :turbo_stream)
        expect(response.body).to include('data-controller="prefetch-frame"')
      end
    end

    context "personalized rendering" do
      let!(:creator) { create(:alias) }
      let!(:topic) { create(:topic, creator: creator) }
      let!(:message_a) { create(:message, topic: topic, sender: creator, created_at: 2.hours.ago) }
      let!(:message_b) { create(:message, topic: topic, sender: creator, created_at: 1.hour.ago) }

      context "as a guest" do
        it "renders neutral rows without user-state frame plumbing" do
          get topics_path
          expect(response.body).to include('class="topic-row"')
          expect(response.body).not_to include("topic-new")
          expect(response.body).not_to include("user-state-root")
          expect(response.body).not_to include("user-state-requests")
        end
      end

      context "when signed in" do
        let(:user) { create(:user) }

        before { sign_in_as(user) }

        it "renders personalized rows in the initial HTML without the frame" do
          get topics_path
          expect(response.body).to include('class="topic-row topic-new"')
          expect(response.body).not_to include("user-state-root")
          expect(response.body).not_to include("user-state-requests")
        end

        it "marks fully read topics as read" do
          MessageReadRange.add_range(user: user, topic: topic, start_id: message_a.id, end_id: message_b.id)
          get topics_path
          expect(response.body).to include('class="topic-row topic-read"')
        end

        it "renders personalized rows on turbo-stream pagination" do
          get topics_path(format: :turbo_stream)
          expect(response.body).to include('class="topic-row topic-new"')
          expect(response.body).not_to include("user-state-")
        end
      end
    end

    context "ignore filter on index" do
      let!(:user) { create(:user) }
      let!(:normal_topic) { create(:topic) }
      let!(:ignored_topic) { create(:topic) }
      let!(:ignored_and_starred_topic) { create(:topic) }
      let!(:msg1) { create(:message, topic: normal_topic, created_at: 3.hours.ago) }
      let!(:msg2) { create(:message, topic: ignored_topic, created_at: 2.hours.ago) }
      let!(:msg3) { create(:message, topic: ignored_and_starred_topic, created_at: 1.hour.ago) }

      before do
        sign_in_as(user)
        create(:topic_ignore, user: user, topic: ignored_topic)
        create(:topic_ignore, user: user, topic: ignored_and_starred_topic)
        create(:topic_star, user: user, topic: ignored_and_starred_topic)
      end

      it "excludes ignored topics" do
        get topics_path
        expect(response.body).to include(normal_topic.title)
        expect(response.body).not_to include(ignored_topic.title)
      end

      it "shows ignored topics that are also starred (star wins)" do
        get topics_path
        expect(response.body).to include(ignored_and_starred_topic.title)
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

      it "renders the Show all patchsets details when patches exist" do
        create(:attachment, :patch_file, message: root_message)

        get topic_path(topic)

        expect(response).to have_http_status(:success)
        expect(response.body).to include("Show all patchsets")
        expect(response.body).to include("patchsets-sidebar-list")
        expect(response.body).to include(patchsets_sidebar_topic_path(topic))
      end

      it "omits the Show all patchsets details when no patches exist" do
        get topic_path(topic)

        expect(response).to have_http_status(:success)
        expect(response.body).not_to include("Show all patchsets")
        expect(response.body).not_to include("patchsets-sidebar-list")
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

      context "with a full page of results" do
        before do
          25.times do |i|
            topic = create(:topic, title: "PostgreSQL result #{i}", creator: creator1, created_at: (i + 1).days.ago)
            create(:message, topic: topic, sender: creator1, created_at: (i + 1).days.ago)
          end
        end

        it "marks the pagination frame for prefetching" do
          get search_topics_path, params: { q: "PostgreSQL" }
          expect(response.body).to include('data-controller="prefetch-frame"')
        end

        it "marks the replaced pagination frame for prefetching" do
          get search_topics_path, params: { q: "PostgreSQL", format: :turbo_stream }
          expect(response.body).to include('data-controller="prefetch-frame"')
        end
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

    context "when signed in, search renders without user-state frame" do
      let!(:user) { create(:user) }
      let!(:topic1) { create(:topic, title: "pgconf planning") }
      let!(:msg1) { create(:message, topic: topic1, body: "test") }

      before { sign_in_as(user) }

      it "does not include user-state-root turbo frame" do
        get search_topics_path, params: { q: "pgconf" }
        expect(response.body).not_to include('id="user-state-root"')
      end
    end
  end

  describe "GET /topics/search personalization" do
    let!(:creator) { create(:alias) }
    let!(:topic) { create(:topic, creator: creator) }
    let!(:message) { create(:message, topic: topic, sender: creator, body: "zebrafish migration details") }

    it "renders neutral rows without frame plumbing for guests" do
      get search_topics_path(q: "zebrafish")
      expect(response).to have_http_status(:success)
      expect(response.body).not_to include("user-state-root")
      expect(response.body).not_to include("user-state-requests")
      expect(response.body).not_to include("topic-new")
    end

    it "renders personalized rows without the frame when signed in" do
      sign_in_as(create(:user))
      get search_topics_path(q: "zebrafish")
      expect(response).to have_http_status(:success)
      expect(response.body).to include('class="topic-row topic-new"')
      expect(response.body).not_to include("user-state-root")
    end
  end

  describe "GET /topics/row_states" do
    let!(:creator) { create(:alias) }
    let!(:user) { create(:user) }
    let!(:topic) { create(:topic, creator: creator) }
    let!(:other_topic) { create(:topic, creator: creator) }
    let!(:message1) { create(:message, topic: topic, sender: creator, created_at: 2.hours.ago) }
    let!(:message2) { create(:message, topic: topic, sender: creator, created_at: 1.hour.ago) }
    let!(:other_message) { create(:message, topic: other_topic, sender: creator) }

    it "requires authentication" do
      get row_states_topics_path, params: { topic_ids: [ topic.id ] }, as: :turbo_stream
      expect(response).to redirect_to(new_session_path)
    end

    context "when signed in" do
      before { sign_in_as(user) }

      it "replaces only the requested rows" do
        get row_states_topics_path, params: { topic_ids: [ topic.id ] }, as: :turbo_stream

        expect(response).to have_http_status(:success)
        expect(response.body).to include(%(target="topic_#{topic.id}"))
        expect(response.body).not_to include(%(target="topic_#{other_topic.id}"))
      end

      it "reflects a topic that has been fully read" do
        MessageReadRange.add_range(user: user, topic: topic, start_id: message1.id, end_id: message2.id)

        get row_states_topics_path, params: { topic_ids: [ topic.id ] }, as: :turbo_stream

        expect(response.body).to include("topic-row topic-read")
        expect(response.body).to include("status-read")
      end

      it "still returns a row for an ignored topic" do
        create(:topic_ignore, user: user, topic: topic)

        get row_states_topics_path, params: { topic_ids: [ topic.id ] }, as: :turbo_stream

        expect(response.body).to include(%(target="topic_#{topic.id}"))
        expect(response.body).to include("is-ignored")
      end

      it "tolerates zero, negative, non numeric and unknown ids" do
        get row_states_topics_path,
            params: { topic_ids: [ "0", "-5", "abc", "99999999", topic.id.to_s ] },
            as: :turbo_stream

        expect(response).to have_http_status(:success)
        expect(response.body).to include(%(target="topic_#{topic.id}"))
      end

      it "replaces every requested row in one response" do
        get row_states_topics_path,
            params: { topic_ids: [ topic.id, other_topic.id ] },
            as: :turbo_stream

        expect(response).to have_http_status(:success)
        expect(response.body).to include(%(target="topic_#{topic.id}"))
        expect(response.body).to include(%(target="topic_#{other_topic.id}"))
      end

      it "returns an empty stream when no id is usable" do
        get row_states_topics_path, params: { topic_ids: [ "abc" ] }, as: :turbo_stream

        expect(response).to have_http_status(:success)
        expect(response.body).not_to include("turbo-stream")
      end

      it "caps the number of processed ids" do
        ids = Array.new(TopicsController::ROW_STATES_LIMIT + 5) { |i| topic.id + 1000 + i }
        ids << topic.id

        get row_states_topics_path, params: { topic_ids: ids }, as: :turbo_stream

        expect(response).to have_http_status(:success)
        expect(response.body).not_to include(%(target="topic_#{topic.id}"))
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

  describe "GET /topics/:id/summary" do
    let!(:creator) { create(:alias, name: "Alice", email: "alice@example.com") }
    let!(:topic) { create(:topic, creator: creator, title: "Patch topic") }
    let!(:plain_message) { create(:message, topic: topic, sender: creator, created_at: 2.hours.ago) }
    let!(:patch_message) { create(:message, topic: topic, sender: creator, created_at: 1.hour.ago, subject: "v1 patch") }
    let!(:patch1) { create(:attachment, :patch_file, message: patch_message, file_name: "v1.patch") }
    let!(:noise_attachment) { create(:attachment, message: patch_message, file_name: "notes.txt", content_type: "text/plain") }

    it "returns topic summary with patchset list" do
      get summary_topic_path(topic)

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("application/json")
      json = JSON.parse(response.body)

      expect(json["id"]).to eq(topic.id)
      expect(json["title"]).to eq("Patch topic")
      expect(json["creator"]).to eq("name" => "Alice", "email" => "alice@example.com")
      expect(json["url"]).to include("/topics/#{topic.id}")

      expect(json["patchsets"].size).to eq(1)
      patchset = json["patchsets"].first
      expect(patchset["message_id"]).to eq(patch_message.id)
      expect(patchset["subject"]).to eq("v1 patch")
      expect(patchset["patch_count"]).to eq(1)
      expect(patchset["download_url"]).to include("/messages/#{patch_message.id}/patchset")
    end

    it "returns 404 for unknown topic" do
      bogus_id = Topic.maximum(:id).to_i + 1_000_000
      get summary_topic_path(id: bogus_id)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /topics/:id/messages" do
    let!(:creator) { create(:alias, name: "Bob", email: "bob@example.com") }
    let!(:topic) { create(:topic, creator: creator) }
    let!(:root_msg) { create(:message, topic: topic, sender: creator, reply_to: nil, created_at: 2.hours.ago, body: "root body") }
    let!(:reply_msg) { create(:message, topic: topic, sender: creator, reply_to: root_msg, created_at: 1.hour.ago, body: "reply body") }
    let!(:attachment) { create(:attachment, :patch_file, message: reply_msg, file_name: "fix.patch") }

    it "returns all messages with bodies and attachment links" do
      get messages_topic_path(topic)

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)

      expect(json["topic_id"]).to eq(topic.id)
      expect(json["messages"].size).to eq(2)

      first, second = json["messages"]
      expect(first["id"]).to eq(root_msg.id)
      expect(first["body"]).to eq("root body")
      expect(first["reply_to_id"]).to be_nil
      expect(first["attachments"]).to eq([])

      expect(second["id"]).to eq(reply_msg.id)
      expect(second["body"]).to eq("reply body")
      expect(second["reply_to_id"]).to eq(root_msg.id)
      expect(second["is_patch_submission"]).to eq(true)
      expect(second["attachments"].size).to eq(1)
      att = second["attachments"].first
      expect(att["file_name"]).to eq("fix.patch")
      expect(att["url"]).to include("/attachments/#{attachment.id}")
    end

    it "returns 404 for unknown topic" do
      bogus_id = Topic.maximum(:id).to_i + 1_000_000
      get messages_topic_path(id: bogus_id)
      expect(response).to have_http_status(:not_found)
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

  describe "POST /topics/:id/ignore" do
    let!(:user) { create(:user) }
    let!(:creator) { create(:alias) }
    let!(:topic) { create(:topic, creator: creator) }
    let!(:message) { create(:message, topic: topic, sender: creator) }

    context "when signed in" do
      before { sign_in_as(user) }

      it "creates a TopicIgnore record" do
        expect {
          post ignore_topic_path(topic), headers: { "Accept" => "application/json" }
        }.to change(TopicIgnore, :count).by(1)
        expect(response).to have_http_status(:success)
        expect(JSON.parse(response.body)["ignored"]).to be true
      end

      it "is idempotent" do
        create(:topic_ignore, user: user, topic: topic)
        expect {
          post ignore_topic_path(topic), headers: { "Accept" => "application/json" }
        }.not_to change(TopicIgnore, :count)
        expect(response).to have_http_status(:success)
      end
    end

    context "when not signed in" do
      it "redirects to sign in" do
        post ignore_topic_path(topic)
        expect(response).to redirect_to(new_session_path)
      end
    end
  end

  describe "DELETE /topics/:id/unignore" do
    let!(:user) { create(:user) }
    let!(:creator) { create(:alias) }
    let!(:topic) { create(:topic, creator: creator) }
    let!(:message) { create(:message, topic: topic, sender: creator) }

    context "when signed in" do
      before do
        sign_in_as(user)
        create(:topic_ignore, user: user, topic: topic)
      end

      it "destroys the TopicIgnore record" do
        expect {
          delete unignore_topic_path(topic), headers: { "Accept" => "application/json" }
        }.to change(TopicIgnore, :count).by(-1)
        expect(response).to have_http_status(:success)
        expect(JSON.parse(response.body)["ignored"]).to be false
      end
    end
  end
end

RSpec.describe 'Topics show — drafts sidebar', type: :request do
  let(:user)     { create(:user) }
  let!(:identity) { create(:identity, user: user, email: 'a@b', refresh_token: 'r', send_authorized_at: 1.hour.ago) }
  let!(:sender)  { create(:alias, user: user, email: 'a@b', name: 'Alice') }
  let(:list)     { create(:mailing_list, post_address: 'real@list.example') }
  let(:topic)    { create(:topic, mailing_lists: [ list ]) }
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

  describe "GET /topics/:id/patchsets_sidebar" do
    let!(:creator) { create(:alias) }
    let!(:topic)   { create(:topic, creator: creator) }

    context "with multiple patch-submission messages" do
      let!(:msg_v1) do
        create(:message, topic: topic, sender: creator, created_at: 2.days.ago)
      end
      let!(:patch_v1) { create(:attachment, :patch_file, message: msg_v1) }
      let!(:msg_v2) do
        create(:message, topic: topic, sender: creator, created_at: 1.hour.ago)
      end
      let!(:patch_v2) { create(:attachment, :patch_file, message: msg_v2) }
      let!(:non_patch_msg) do
        create(:message, topic: topic, sender: creator, created_at: 1.day.ago)
      end

      it "lists patch-submission messages newest first" do
        get patchsets_sidebar_topic_path(topic)
        expect(response).to have_http_status(:ok)
        body = response.body
        v2_pos = body.index("message-#{msg_v2.id}")
        v1_pos = body.index("message-#{msg_v1.id}")
        expect(v2_pos).to be < v1_pos
        expect(body).not_to include("message-#{non_patch_msg.id}")
      end

      it "renders a download link per patchset" do
        get patchsets_sidebar_topic_path(topic)
        expect(response.body).to include(message_patchset_path(msg_v1))
        expect(response.body).to include(message_patchset_path(msg_v2))
      end
    end

    context "with no patch-submission messages" do
      let!(:msg) { create(:message, topic: topic, sender: creator) }

      it "renders the empty-state copy" do
        get patchsets_sidebar_topic_path(topic)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("No patchsets in this thread")
      end
    end

    context "when the topic has patch branches" do
      let!(:msg) { create(:message, topic: topic, sender: creator) }
      let!(:branch) { create(:patch_branch, topic: topic, message: msg) }

      it "links the CI history page" do
        get patchsets_sidebar_topic_path(topic)

        expect(response.body).to include(ci_topic_path(topic))
        expect(response.body).to include("CI history")
        # inside a lazily-loaded frame a plain link fetches the page into the
        # frame, finds no matching frame and silently discards it
        expect(response.body).to include('data-turbo-frame="_top"')
      end
    end

    context "when the topic has no patch branches" do
      let!(:msg) { create(:message, topic: topic, sender: creator) }

      it "offers no CI history link" do
        get patchsets_sidebar_topic_path(topic)

        expect(response.body).not_to include("CI history")
      end
    end
  end
end
