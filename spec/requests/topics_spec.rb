require 'rails_helper'

RSpec.describe "Topics", type: :request do
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
        # topic2 has more recent message, should appear first
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

      it "shows flat view by default (oldest first)" do
        get topic_path(topic)
        expect(response.body).to include('messages-container flat')
        # root should appear before reply
        root_position = response.body.index(root_message.body)
        reply_position = response.body.index(reply_message.body)
        expect(root_position).to be < reply_position
      end
    end

    context "with descending sort" do
      it "still shows oldest first (descending disabled)" do
        get topic_path(topic, view: 'flat', sort: 'desc')
        expect(response).to have_http_status(:success)
        root_position = response.body.index(root_message.body)
        reply_position = response.body.index(reply_message.body)
        expect(root_position).to be < reply_position
      end
    end

    context "with nonexistent topic" do
      it "returns 404" do
        get topic_path(id: 99999)
        expect(response).to have_http_status(:not_found)
      end
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
        expect(response).to have_http_status(:success)
        expect(response.body).to include("Search the PostgreSQL Hackers Archive")
      end
    end

    context "with empty search query" do
      it "shows search form" do
        get search_topics_path, params: { q: "   " }
        expect(response).to have_http_status(:success)
        expect(response.body).to include("Search the PostgreSQL Hackers Archive")
      end
    end

    context "with no results" do
      it "shows no results message" do
        get search_topics_path, params: { q: "nonexistent" }
        expect(response.body).to include("No results found")
      end
    end
  end
end
