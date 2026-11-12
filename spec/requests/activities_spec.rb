require "rails_helper"

RSpec.describe "Activities", type: :request do
  def sign_in(email:, password: "secret")
    post session_path, params: { email: email, password: password }
    expect(response).to redirect_to(root_path)
  end

  def sign_in_as(user)
    delete session_path
    email = "#{user.username}@example.com"
    unless Alias.by_email(email).exists?
      row = create(:alias, user: user, email: email)
      user.person.update!(default_alias_id: row.id) if user.person.default_alias_id.nil?
      Alias.by_email(email).update_all(verified_at: Time.current)
    end
    sign_in(email: email)
  end

  def activity_page(user, **params)
    sign_in_as(user)
    get activities_path, params: params
    expect(response).to have_http_status(:ok)
    response.body
  end

  let!(:topic) { create(:topic, title: "Thread with a note") }
  let!(:author) { create(:user, username: "alice", password: "secret", password_confirmation: "secret") }
  let!(:reader) { create(:user, username: "bob", password: "secret", password_confirmation: "secret") }
  let!(:team) { create(:team, name: "reviewers") }
  let(:missing) { "Content not available anymore." }

  before do
    create(:team_member, team: team, user: author, role: "admin")
    create(:team_member, team: team, user: reader, role: "member")
  end

  def write_note(body)
    NoteBuilder.new(author: author).create!(topic: topic, body: body)
  end

  def expect_shown(page)
    expect(page).to include("the zebra plan", "#todo", "Thread with a note")
    expect(page).not_to include(missing)
  end

  def expect_withheld(page)
    expect(page).to include("Note mentioned", missing)
    expect(page).not_to include("zebra", "#todo", "Thread with a note")
  end

  it "shows a mentioned user the snippet and the tags of the note" do
    write_note("the zebra plan @bob #todo")

    expect_shown(activity_page(reader))
    expect_shown(activity_page(reader, q: "zebra"))
    expect(activity_page(reader, q: "giraffe")).not_to include("Note mentioned")
  end

  it "withholds the note after the user's mention was removed" do
    note = write_note("the zebra plan @bob #todo")
    sign_in_as(reader)
    delete note_mention_path(note.note_mentions.sole)
    expect(note.note_mentions.count).to eq(0)
    expect(reader.activities.visible.where(subject: note)).to exist

    expect_withheld(activity_page(reader))
    expect(activity_page(reader, q: "zebra")).not_to include("Note mentioned", "zebra plan", missing)
    expect_shown(activity_page(author))
    expect_shown(activity_page(author, q: "zebra"))
  end

  it "withholds the note after the user left the mentioned team" do
    note = write_note("the zebra plan @reviewers #todo")
    expect_shown(activity_page(reader))

    delete settings_team_team_member_path(team, team.team_members.find_by!(user: reader))
    expect(team.team_members.where(user: reader)).not_to exist
    expect(reader.activities.visible.where(subject: note)).to exist

    expect_withheld(activity_page(reader))
    expect(activity_page(reader, q: "zebra")).not_to include("Note mentioned", "zebra plan", missing)
    expect_shown(activity_page(author))
  end

  it "withholds a deleted note" do
    note = write_note("the zebra plan @bob #todo")
    note.update_columns(deleted_at: Time.current)

    expect_withheld(activity_page(reader))
  end

  it "asks for the visible notes once, however many entries there are" do
    3.times { |i| write_note("the zebra plan #{i} @bob #todo") }
    sign_in_as(reader)

    queries = captured_queries { get activities_path }

    expect(response.body.scan("the zebra plan").size).to eq(3)
    expect(queries.grep(/nm_user/).size).to eq(1)
  end

  describe "opening an entry" do
    def entry_of(user, note)
      user.activities.visible.find_by!(subject: note)
    end

    it "goes to the note the user can see" do
      note = write_note("the zebra plan @bob #todo")
      sign_in_as(reader)

      get read_activity_path(entry_of(reader, note))

      expect(response).to redirect_to(topic_path(topic, anchor: "thread-notes"))
      expect(entry_of(reader, note).read_at).to be_present
    end

    it "does not go to a note the user can no longer see, and marks the entry read" do
      note = write_note("the zebra plan @bob #todo")
      sign_in_as(reader)
      delete note_mention_path(note.note_mentions.sole)
      entry = entry_of(reader, note)
      expect(entry.read_at).to be_nil

      get read_activity_path(entry)

      expect(response).to redirect_to(activities_path)
      expect(response.location).not_to include("topic")
      expect(flash[:notice]).to eq("This note is no longer available.")
      expect(entry.reload.read_at).to be_present
      follow_redirect!
      expect(response.body).to include("This note is no longer available.", missing)
      expect(response.body).not_to include("zebra", "Thread with a note", "Mark read")
    end

    it "does not go to a deleted note" do
      note = write_note("the zebra plan @bob #todo")
      note.update_columns(deleted_at: Time.current)
      sign_in_as(reader)

      get read_activity_path(entry_of(reader, note))

      expect(response).to redirect_to(activities_path)
      expect(entry_of(reader, note).read_at).to be_present
    end

    it "offers to mark an unread withheld entry read, and only that one" do
      note = write_note("the zebra plan @bob #todo")
      note.update_columns(deleted_at: Time.current)

      page = Nokogiri::HTML(activity_page(reader))
      link = page.at_css(".activity-card .activity-mark-read")

      expect(link.text).to eq("Mark read")
      expect(link["href"]).to eq(read_activity_path(entry_of(reader, note)))
      expect(page.css(".activity-mark-read").size).to eq(1)

      write_note("the lion plan @bob")
      expect(Nokogiri::HTML(activity_page(reader)).css(".activity-mark-read").size).to eq(1)
    end
  end
end
