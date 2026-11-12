require "rails_helper"

RSpec.describe Api::V1::TopicMeData do
  let(:user) { create(:user) }
  let(:other) { create(:user) }
  let(:sender) { create(:alias) }

  def thread(messages: 3, at: 2.days.ago)
    topic = create(:topic, creator_alias: sender)
    Array.new(messages) { |i| create(:message, topic: topic, sender: sender, created_at: at + i.minutes) }
    topic.reload
  end

  def read(topic, first, last = first, by: user)
    ids = topic.messages.order(:created_at, :id).pluck(:id)
    MessageReadRange.add_range(user: by, topic: topic, start_id: ids[first], end_id: ids[last])
  end

  def aware(topic, by: user)
    ThreadAwareness.mark_until(user: by, topic: topic, until_message_id: topic.last_message_id)
  end

  def site_status(topics, topic)
    TopicListPersonalization.new(user: user, topics: topics).state_for(topic)[:status].to_s
  end

  it "gives the state of the user and of nobody else" do
    topic = thread
    quiet = thread
    read(topic, 0, 1)
    aware(topic)
    create(:topic_star, user: user, topic: topic)
    create(:topic_ignore, user: user, topic: topic)
    read(quiet, 0, 2, by: other)
    aware(quiet, by: other)
    create(:topic_star, user: other, topic: quiet)
    create(:topic_ignore, user: other, topic: quiet)
    create(:note, topic: quiet, author: other)

    data = described_class.new(user, [ topic, quiet ])

    expect(data.for(topic)).to eq(starred: true, ignored: true, status: "reading", read_count: 2,
                                  unread_count: 1, note_count: 0)
    expect(data.for(quiet)).to eq(starred: false, ignored: false, status: "new", read_count: 0,
                                  unread_count: 3, note_count: 0)
  end

  it "has the status the site list has" do
    untouched = thread
    seen = thread
    partly = thread
    done = thread
    done_and_seen = thread
    empty = create(:topic, creator_alias: sender)
    aware(seen)
    read(partly, 1)
    read(done, 0, 2)
    read(done_and_seen, 0, 2)
    aware(done_and_seen)
    topics = [ untouched, seen, partly, done, done_and_seen, empty ]

    data = described_class.new(user, topics)

    expect(topics.map { |topic| data.for(topic)[:status] }).to eq(%w[new aware reading read read new])
    topics.each { |topic| expect(data.for(topic)[:status]).to eq(site_status(topics, topic)) }
  end

  it "follows aware_before as the site list does" do
    old = thread(at: 10.days.ago)
    recent = thread(at: 1.day.ago)
    recent_seen = thread(at: 1.day.ago)
    old_partly = thread(at: 10.days.ago)
    old_done = thread(at: 10.days.ago)
    silent = create(:topic, creator_alias: sender)
    aware(recent_seen)
    read(old_partly, 0)
    read(old_done, 0, 2)
    user.update!(aware_before: 5.days.ago)
    topics = [ old, recent, recent_seen, old_partly, old_done, silent ]

    data = described_class.new(user, topics)

    expect(topics.map { |topic| data.for(topic)[:status] }).to eq(%w[aware new aware reading read new])
    topics.each { |topic| expect(data.for(topic)[:status]).to eq(site_status(topics, topic)) }
  end

  it "never counts below zero when more is read than the topic has" do
    topic = thread
    read(topic, 0, 2)
    topic.update_columns(message_count: 2)

    state = described_class.new(user, [ topic ]).for(topic)

    expect(state).to include(read_count: 3, unread_count: 0, status: "read")
    expect(state[:status]).to eq(site_status([ topic ], topic))
  end

  it "counts the notes the site counts" do
    topic = thread
    team = create(:team)
    create(:team_member, team: team, user: user)
    create(:team_member, team: team, user: other)
    foreign_team = create(:team)
    create(:note, topic: topic, author: user)
    create(:note, topic: topic, author: other, global: true)
    create(:note_mention, note: create(:note, topic: topic, author: other), mentionable: user)
    create(:note_mention, note: create(:note, topic: topic, author: other), mentionable: team)
    both = create(:note, topic: topic, author: other)
    create(:note_mention, note: both, mentionable: user)
    create(:note_mention, note: both, mentionable: team)
    create(:note, topic: topic, author: other)
    create(:note_mention, note: create(:note, topic: topic, author: other), mentionable: foreign_team)
    create(:note, topic: topic, author: user, deleted_at: Time.current)
    bare = thread

    data = described_class.new(user, [ topic, bare ])
    site = TopicListPersonalization.new(user: user, topics: [ topic, bare ])

    expect(data.for(topic)[:note_count]).to eq(5)
    expect(data.for(topic)[:note_count]).to eq(site.note_count_for(topic))
    expect(data.for(topic)[:note_count]).to eq(Note.visible_to(user).active.where(topic_id: topic.id).count)
    expect(data.for(bare)[:note_count]).to eq(0)
  end

  it "runs five queries for any number of topics, and none without topics" do
    topics = Array.new(3) { thread }
    read(topics.first, 0)
    user

    one = captured_queries do
      data = described_class.new(user, topics.first(1))
      data.for(topics.first)
    end
    three = captured_queries do
      data = described_class.new(user, topics)
      2.times { topics.each { |topic| data.for(topic) } }
    end
    none = captured_queries { described_class.new(user, []) }

    expect(one.size).to eq(5)
    expect(three.size).to eq(5)
    expect(none).to be_empty
    expect((one + three).grep(/team_members/).grep_v(/FROM "notes"/)).to be_empty
  end

  describe "#first_unread_message_id" do
    it "is the first message in thread order outside the read ranges" do
      topic = thread(messages: 5)
      ids = topic.messages.order(:created_at, :id).pluck(:id)
      data = described_class.new(user, [ topic ])

      expect(data.first_unread_message_id(topic)).to eq(ids[0])

      read(topic, 0, 1)
      read(topic, 3)
      read(topic, 2, by: other)
      expect(data.first_unread_message_id(topic)).to eq(ids[2])

      read(topic, 2)
      expect(data.first_unread_message_id(topic)).to eq(ids[4])

      read(topic, 4)
      expect(data.first_unread_message_id(topic)).to be_nil
    end

    it "goes by time, not by id" do
      topic = thread(messages: 2, at: 2.days.ago)
      late_id_early_time = create(:message, topic: topic, sender: sender, created_at: 3.days.ago)
      data = described_class.new(user, [ topic ])

      expect(data.first_unread_message_id(topic)).to eq(late_id_early_time.id)

      MessageReadRange.add_range(user: user, topic: topic, start_id: late_id_early_time.id,
                                 end_id: late_id_early_time.id)
      expect(data.first_unread_message_id(topic)).to eq(topic.messages.order(:created_at, :id).first(2).last.id)
    end

    it "runs one query" do
      topic = thread
      data = described_class.new(user, [ topic ])

      expect(captured_queries { data.first_unread_message_id(topic) }.size).to eq(1)
    end
  end
end
