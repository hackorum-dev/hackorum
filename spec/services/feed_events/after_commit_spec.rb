require "rails_helper"

RSpec.describe FeedEvents::Recorder, "and the writer's transaction" do
  self.use_transactional_tests = false

  let(:created) { { messages: [] } }

  around do |example|
    created[:counts] = row_counts
    example.run
  ensure
    clean_up
  end

  def row_counts
    connection = ActiveRecord::Base.lease_connection
    connection.tables.to_h { |table| [ table, connection.select_value("SELECT count(*) FROM #{connection.quote_table_name(table)}") ] }
  end

  def mail
    created[:topic] ||= create(:topic)
    create(:message, topic: created[:topic], sender: created[:topic].creator).tap { |row| created[:messages] << row }
  end

  # by id, children first: nothing here runs in a transaction that is rolled back
  def clean_up
    topic = created[:topic]
    return unless topic

    person = topic.creator.person_id
    TopicParticipant.where(topic_id: topic.id).delete_all
    Topic.where(id: topic.id).update_all(last_message_id: nil)
    Message.where(id: created[:messages].map(&:id)).delete_all
    Topic.where(id: topic.id).delete_all
    Person.where(id: person).update_all(default_alias_id: nil)
    Alias.where(id: topic.creator_id).delete_all
    Person.where(id: person).delete_all
    expect(row_counts).to eq(created[:counts])
  end

  def elsewhere(&block)
    Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }.value
  end

  def events_of(message)
    FeedEvent.where(message_id: message.id)
  end

  def seen_elsewhere(message)
    elsewhere { events_of(message).count }
  end

  def age(message)
    events_of(message).update_all("created_at = clock_timestamp() - interval '10 seconds'")
  end

  # a writer on its own connection, its transaction open until the block is over
  def while_writing(message)
    entered = Queue.new
    release = Queue.new
    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ApplicationRecord.transaction do
          described_class.message_received(message)
          entered << true
          release.pop
        end
      end
    ensure
      entered << true
    end
    entered.pop
    yield
  ensure
    release << true
    writer.join
  end

  it "inserts nothing while the transaction is open, and the row once it commits" do
    message = mail

    ApplicationRecord.transaction do
      described_class.message_received(message)
      described_class.patchset_posted(message)

      expect(events_of(message).count).to eq(0)
      expect(seen_elsewhere(message)).to eq(0)
    end

    expect(events_of(message).order(:id).pluck(:event_type)).to eq(%w[message.received patchset.posted])
    expect(seen_elsewhere(message)).to eq(2)
  end

  it "waits for the outermost transaction" do
    message = mail

    ApplicationRecord.transaction do
      ApplicationRecord.transaction(requires_new: true) { described_class.message_received(message) }
      expect(events_of(message).count).to eq(0)
    end

    expect(events_of(message).count).to eq(1)
  end

  it "inserts nothing after a rollback" do
    message = mail

    ApplicationRecord.transaction do
      described_class.message_received(message)
      raise ActiveRecord::Rollback
    end

    expect(events_of(message).count).to eq(0)
    expect(seen_elsewhere(message)).to eq(0)
  end

  it "inserts at once without a transaction" do
    message = mail

    described_class.message_received(message)

    expect(seen_elsewhere(message)).to eq(1)
  end

  it "does not lose the event of a writer that commits after a later one was read" do
    slow = mail
    fast = mail
    start = Api::EventFeed.encode(FeedEvent.maximum(:id).to_i)
    first = nil

    while_writing(slow) do
      described_class.message_received(fast)
      age(fast)
      first = Api::EventFeed.new(since: start).page
    end
    age(slow)
    second = Api::EventFeed.new(since: first.next_cursor).page

    expect(first.events.map(&:message_id)).to eq([ fast.id ])
    expect(second.events.map(&:message_id)).to eq([ slow.id ])
    expect(Api::EventFeed.new(since: second.next_cursor).page.events).to be_empty
  end
end
