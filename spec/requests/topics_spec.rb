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

    context "when requesting a team view" do
      let!(:team) { create(:team) }
      let!(:member) { create(:user, password: 'secret', password_confirmation: 'secret') }
      let!(:non_member) { create(:user, password: 'secret', password_confirmation: 'secret') }

      before do
        create(:team_member, team: team, user: member)
      end

      it "redirects guests to sign in" do
        get topics_path, params: { team_id: team.id }
        expect(response).to redirect_to(new_session_path)
      end

      it "returns 404 for signed-in non-members" do
        attach_verified_alias(non_member, email: "non-member@example.com")
        sign_in(email: "non-member@example.com")

        get topics_path, params: { team_id: team.id }
        expect(response).to have_http_status(:not_found)
      end

      it "allows signed-in team members" do
        attach_verified_alias(member, email: "member@example.com")
        sign_in(email: "member@example.com")

        get topics_path, params: { team_id: team.id }
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

      it "renders patch attachments inline as expandable diff blocks" do
        create(:attachment, :patch_file, message: root_message)

        get topic_path(topic)

        expect(response).to have_http_status(:success)
        expect(response.body).to include("Attachments:")
        expect(response.body).to include('data-controller="diff-highlight"')
        expect(response.body).to include("diff --git")
      end
    end

    context "with nonexistent topic" do
      it "returns 404" do
        get topic_path(id: 99999)
        expect(response).to have_http_status(:not_found)
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
end
