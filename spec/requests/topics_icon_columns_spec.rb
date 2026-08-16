require "rails_helper"

RSpec.describe "Topic index icon columns", type: :request do
  it "reserves no personal slots for guests" do
    create(:topic, :with_messages)

    get root_path

    expect(response.body).to include("topics-table")
    expect(response.body).not_to include("has-personal-icons")
  end

  it "reserves personal slots but no team slot for a user without a team" do
    sign_in_as(create(:user))
    create(:topic, :with_messages)

    get root_path

    expect(response.body).to include("has-personal-icons")
    expect(response.body).not_to include("has-team-icons")
  end

  it "reserves the team slot for a user in a team" do
    user = create(:user)
    create(:team_member, user: user)
    sign_in_as(user)
    create(:topic, :with_messages)

    get root_path

    expect(response.body).to include("has-personal-icons")
    expect(response.body).to include("has-team-icons")
  end

  it "uses the same wrapper classes on the search page" do
    sign_in_as(create(:user))
    create(:topic, :with_messages, title: "logical replication slot")

    get search_topics_path(q: "replication")

    expect(response.body).to include("has-personal-icons")
  end

  it "renders no personal icon slots for guests" do
    create(:topic, :with_messages)

    get root_path

    expect(response.body).not_to include("slot-star")
    expect(response.body).not_to include("slot-note")
    expect(response.body).not_to include("slot-reading")
    expect(response.body).not_to include("slot-team")
  end

  it "renders the shared slots for guests" do
    topic = create(:topic, :with_messages)
    topic.update_columns(has_attachments: true)

    get root_path

    expect(response.body).to include("slot-patch")
  end

  it "renders personal icon slots but no team slot without a team" do
    sign_in_as(create(:user))
    topic = create(:topic, :with_messages)
    topic.update_columns(has_attachments: true)

    get root_path

    expect(response.body).to include("slot-star")
    expect(response.body).to include("slot-note")
    expect(response.body).to include("slot-patch")
    expect(response.body).not_to include("slot-team")
  end

  it "renders the team slot for a user in a team" do
    user = create(:user)
    create(:team_member, user: user)
    sign_in_as(user)
    create(:topic, :with_messages)

    get root_path

    expect(response.body).to include("slot-team")
  end

  it "renders the reading slot only for the signed in user who partially read the topic" do
    user = create(:user)
    topic = create(:topic, :with_messages)
    first_message = topic.messages.order(:id).first
    MessageReadRange.add_range(user: user, topic: topic, start_id: first_message.id, end_id: first_message.id)

    get root_path

    expect(response.body).not_to include("slot-reading")
    expect(response.body).not_to include("topic-icon-reading")
    expect(response.body).not_to include("has-new-replies")

    sign_in_as(user)
    get root_path

    html = Nokogiri::HTML(response.body)
    reading_links = html.css("a.topic-icon-reading.slot-reading")
    expect(reading_links.size).to eq(2)
    expect(reading_links.map { |link| link["href"] }.uniq).to eq([ topic_path(topic, anchor: "first-unread") ])
    expect(html.css("tr.topic-row.topic-reading.has-new-replies").size).to eq(1)
  end

  it "renders the ignore icon in the title line, twice per row" do
    sign_in_as(create(:user))
    create(:topic, :with_messages)

    get root_path

    expect(response.body.scan("topic-title-ignore").size).to eq(2)

    html = Nokogiri::HTML(response.body)
    expect(html.css(".topic-title-icons .topic-title-ignore")).to be_empty
    expect(html.css(".topic-title-text > .topic-title-ignore").size).to eq(2)
  end

  it "renders no ignore icon for guests" do
    create(:topic, :with_messages)

    get root_path

    expect(response.body).not_to include("activity-ignore")
  end

  it "renders mailing list badges inline in the title and in the column" do
    topic = create(:topic, :with_messages)
    list = create(:mailing_list, display_name: "hackers", identifier: "pgsql-hackers")
    create(:topic_mailing_list, topic: topic, mailing_list: list)

    get root_path

    html = Nokogiri::HTML(response.body)
    expect(html.css(".mailing-list-badge").size).to eq(2)
    expect(html.css(".topic-inline-lists").size).to eq(1)
    expect(html.css(".topic-title-main > span.topic-title-text > .topic-inline-lists").size).to eq(1)
    expect(html.css(".topic-title-mobile .topic-inline-lists")).to be_empty
    expect(html.css("td.topic-mailing-lists .mailing-list-badge").size).to eq(1)
  end

  it "renders no badge markup for a topic without mailing lists" do
    create(:topic, :with_messages)

    get root_path

    expect(response.body).not_to include("topic-inline-lists")
    expect(response.body).not_to include("mailing-list-badges")
  end
end
