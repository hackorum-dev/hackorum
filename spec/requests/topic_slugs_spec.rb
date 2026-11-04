require "rails_helper"

RSpec.describe "Topic slugs", type: :request do
  let!(:creator) { create(:alias) }
  let!(:topic) { create(:topic, creator: creator, slug: "my-feature") }
  let!(:message) { create(:message, topic: topic, sender: creator, reply_to: nil) }

  describe "GET /t/:slug" do
    it "renders the topic" do
      get "/t/my-feature"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(topic.title)
    end

    it "ignores case" do
      get "/t/My-Feature"
      expect(response).to have_http_status(:ok)
    end

    it "404s on unknown slug" do
      get "/t/nope"
      expect(response).to have_http_status(:not_found)
    end

    it "404s on a path that is not a slug" do
      get "/t/1abc"
      expect(response).to have_http_status(:not_found)
    end

    it "keeps dots in the slug" do
      topic.update!(slug: "v1.2")
      get "/t/v1.2"
      expect(response).to have_http_status(:ok)
    end

    it "redirects a merged topic to the final one" do
      target = create(:topic)
      create(:message, topic: target)
      topic.update!(merged_into_topic: target)
      get "/t/my-feature"
      expect(response).to have_http_status(:moved_permanently)
      expect(response).to redirect_to(topic_path(target))
    end
  end

  let(:owner) { create(:user, person: topic.creator_person) }
  let(:stream) { { "Accept" => "text/vnd.turbo-stream.html" } }

  describe "PATCH /topics/:id/slug" do
    it "lets the creator set it" do
      sign_in_as(owner)
      patch topic_slug_path(topic), params: { topic: { slug: "New-Name" } }, headers: stream
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("slug_sidebar_topic_#{topic.id}")
      expect(response.body).to include("sidebar-short-link")
      expect(topic.reload.slug).to eq("new-name")
    end

    it "refreshes the docker button with the new slug tag" do
      repo_state = create(:patch_ci_repo_state, master_committed_at: Time.current)
      branch = create(:patch_branch, topic: topic, message: message, branch_name: "t#{topic.id}_1",
                      base_sha: repo_state.master_sha, pushed_at: 1.hour.ago, ci_status: "success")
      create(:patch_ci_run, patch_branch: branch, status: "success",
                            image_ref: "ghcr.io/hackorum-dev/postgres:t#{topic.id}", completed_at: Time.current)
      sign_in_as(owner)

      patch topic_slug_path(topic), params: { topic: { slug: "new-name" } }, headers: stream

      button = Nokogiri::HTML(response.body).at_css("turbo-stream[target=docker_button_topic_#{topic.id}] template button")
      expect(button["title"]).to include("ghcr.io/hackorum-dev/postgres:new-name")
    end

    it "redirects html requests back to the topic" do
      sign_in_as(owner)
      patch topic_slug_path(topic), params: { topic: { slug: "other" } }
      expect(response).to redirect_to(topic_path(topic))
    end

    it "lets admins set it on any topic" do
      sign_in_as(create(:user, admin: true))
      patch topic_slug_path(topic), params: { topic: { slug: "by-admin" } }, headers: stream
      expect(topic.reload.slug).to eq("by-admin")
    end

    it "forbids other users" do
      sign_in_as(create(:user))
      patch topic_slug_path(topic), params: { topic: { slug: "hijack" } }, headers: stream
      expect(response).to have_http_status(:forbidden)
      expect(topic.reload.slug).to eq("my-feature")
    end

    it "requires sign in" do
      patch topic_slug_path(topic), params: { topic: { slug: "anon" } }
      expect(response).to redirect_to(new_session_path)
      expect(topic.reload.slug).to eq("my-feature")
    end

    it "shows the error for a taken slug" do
      create(:topic, slug: "taken")
      sign_in_as(owner)
      patch topic_slug_path(topic), params: { topic: { slug: "taken" } }, headers: stream
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("has already been taken")
      expect(topic.reload.slug).to eq("my-feature")
    end

    it "shows the error for an invalid slug" do
      sign_in_as(owner)
      patch topic_slug_path(topic), params: { topic: { slug: "t42" } }, headers: stream
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("is reserved")
    end
  end

  describe "PATCH edge cases" do
    it "rejects a request without topic params" do
      sign_in_as(owner)
      patch topic_slug_path(topic), headers: stream
      expect(response).to have_http_status(:bad_request)
      expect(topic.reload.slug).to eq("my-feature")
    end

    it "redirects edits of a merged topic to the final one" do
      target = create(:topic)
      topic.update!(merged_into_topic: target)
      sign_in_as(create(:user, admin: true))
      patch topic_slug_path(topic), params: { topic: { slug: "other" } }
      expect(response).to redirect_to(topic_path(target))
      expect(topic.reload.slug).to eq("my-feature")
    end

    it "turns a lost unique race into the taken error" do
      sign_in_as(owner)
      allow_any_instance_of(Topic).to receive(:save).and_raise(ActiveRecord::RecordNotUnique)
      patch topic_slug_path(topic), params: { topic: { slug: "raced" } }, headers: stream
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("has already been taken")
    end
  end

  describe "DELETE /topics/:id/slug" do
    it "clears it" do
      sign_in_as(owner)
      delete topic_slug_path(topic), headers: stream
      expect(response).to have_http_status(:ok)
      expect(topic.reload.slug).to be_nil
    end
  end

  describe "sidebar" do
    it "shows the copyable short link to everyone" do
      get topic_path(topic)
      expect(response.body).to include("/t/my-feature")
      expect(response.body).to include(%(data-clipboard-url-value="#{short_topic_url('my-feature')}"))
      expect(response.body).not_to include("slug-sidebar-form")
    end

    it "shows the form to editors" do
      sign_in_as(owner)
      get topic_path(topic)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("slug-sidebar-form")
    end

    it "shows nothing to non-editors when there is no slug" do
      topic.update!(slug: nil)
      get topic_path(topic)
      expect(response.body).not_to include("slug_sidebar_topic_#{topic.id}")
    end
  end
end
