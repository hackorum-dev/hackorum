require "rails_helper"

RSpec.describe Api::EventFeed do
  let(:alice) { create(:alias, :with_sent_messages, email: "alice.a@example.org") }
  let(:bob) { create(:alias, :with_sent_messages, email: "bob@example.org") }
  let(:topic) { create(:topic, creator_alias: alice) }

  def feed(**options)
    described_class.new(**options).page
  end

  def ids(page)
    page.events.map(&:id)
  end

  def position(cursor)
    JSON.parse(Base64.urlsafe_decode64(cursor)).last
  end

  def cursor_at(id)
    described_class.encode(id)
  end

  describe "positions" do
    it "returns the events after a duration oldest first, and only newer ones from its cursor" do
      old = message_event(topic: topic, at: 3.days.ago)
      first = message_event(topic: topic, at: 2.hours.ago)
      second = message_event(topic: topic, at: 1.hour.ago)

      page = feed(since: "1d")
      expect(ids(page)).to eq([ first.id, second.id ])
      expect(page.has_more).to be(false)
      expect(ids(feed(since: "7d"))).to eq([ old.id, first.id, second.id ])

      expect(ids(feed(since: page.next_cursor))).to eq([])
      third = message_event(topic: topic)
      expect(ids(feed(since: page.next_cursor))).to eq([ third.id ])
    end

    it "defaults to the last 24 hours" do
      message_event(topic: topic, at: 25.hours.ago)
      inside = message_event(topic: topic, at: 23.hours.ago)

      expect(ids(feed)).to eq([ inside.id ])
    end

    it "takes a timestamp with Z or an offset, by arrival and not by the date of the mail" do
      message_event(topic: topic, at: 3.hours.ago)
      late = message_event(topic: topic, at: 1.hour.ago, created_at: 2.years.ago)

      expect(late.occurred_at).to be < 1.year.ago
      expect(ids(feed(since: 2.hours.ago.utc.iso8601))).to eq([ late.id ])
      expect(ids(feed(since: 2.hours.ago.in_time_zone("Europe/Budapest").iso8601(3)))).to eq([ late.id ])
    end

    it "pages without a gap or a repeat, also over rows that are not shown" do
      hidden = create(:topic, hidden_by_default: true)
      shown = []
      9.times do |i|
        message_event(topic: hidden) if i.odd?
        shown << message_event(topic: topic).id
      end
      message_event(topic: hidden)

      seen = []
      cursor = "1d"
      pages = 0
      loop do
        page = feed(since: cursor, limit: "4")
        seen.concat(ids(page))
        cursor = page.next_cursor
        pages += 1
        break unless page.has_more
      end

      expect(seen).to eq(shown)
      expect(pages).to eq(3)
      expect(position(cursor)).to eq(FeedEvent.maximum(:id))
    end

    it "says has_more only when a row is waiting" do
      3.times { message_event(topic: topic) }

      expect(feed(limit: "3").has_more).to be(false)
      page = feed(limit: "2")
      expect(page.has_more).to be(true)
      expect(position(page.next_cursor)).to eq(page.events.last.id)
    end

    it "gives a cursor on an empty table and returns what comes after from it" do
      page = feed
      expect(ids(page)).to eq([])
      expect(page.has_more).to be(false)
      expect(position(page.next_cursor)).to eq(0)

      first = message_event(topic: topic)
      expect(ids(feed(since: page.next_cursor))).to eq([ first.id ])
    end

    it "gives an empty page at the horizon for a timestamp in the future" do
      last = message_event(topic: topic)

      [ 1.hour.from_now.utc.iso8601, "9999-12-31T23:59:59+00:00" ].each do |later|
        page = feed(since: later)
        expect(ids(page)).to eq([])
        expect(position(page.next_cursor)).to eq(last.id)
      end
    end

    it "never moves a cursor back" do
      last = message_event(topic: topic)
      ahead = cursor_at(last.id + 10)

      page = feed(since: ahead)
      expect(ids(page)).to eq([])
      expect(page.next_cursor).to eq(ahead)
    end

    it "is one query when nothing is new, and two for a page" do
      message_event(topic: topic)
      cursor = feed.next_cursor

      expect(captured_queries { feed(since: cursor) }.size).to eq(1)
      message_event(topic: topic)
      expect(captured_queries { feed(since: cursor) }.size).to eq(2)
    end
  end

  describe "the hold-back" do
    it "keeps an event of the last seconds for later and does not move past it" do
      before = message_event(topic: topic)
      young = message_event(topic: topic, age: 2.seconds)

      page = feed
      expect(ids(page)).to eq([ before.id ])
      expect(position(page.next_cursor)).to eq(before.id)

      aged(young, 6.seconds)
      expect(ids(feed(since: page.next_cursor))).to eq([ young.id ])
    end

    it "measures the age on the database clock, whatever the clock here says" do
      old = message_event(topic: topic, age: 10.seconds)
      young = message_event(topic: topic, age: 1.second)

      [ 1.hour.ago, 1.hour.from_now ].each do |time|
        travel_to(time) { expect(ids(feed(since: cursor_at(0)))).to eq([ old.id ]) }
      end
      travel_to(1.hour.ago) { expect(ids(feed(since: "5m"))).to eq([ old.id ]) }
      expect(young.id).to be > old.id
    end

    it "holds every row behind a young one, whatever its own age" do
      before = message_event(topic: topic)
      young = message_event(topic: topic, age: 1.second)
      after = message_event(topic: topic, age: 10.seconds)

      page = feed
      expect(ids(page)).to eq([ before.id ])
      expect(position(page.next_cursor)).to eq(before.id)
      aged(young, 6.seconds)
      expect(ids(feed(since: page.next_cursor))).to eq([ young.id, after.id ])
    end

    it "stops at the last row that is old enough, not in the ids below a young one" do
      before = message_event(topic: topic)
      gap = message_event(topic: topic)
      young = message_event(topic: topic, age: 1.second)
      FeedEvent.where(id: gap.id).delete_all

      expect(position(feed.next_cursor)).to eq(before.id)
      expect(young.id).to be > before.id + 1
    end

    it "returns nothing while every row is young" do
      message_event(topic: topic, age: 1.second)

      page = feed
      expect(ids(page)).to eq([])
      expect(position(page.next_cursor)).to eq(0)
    end
  end

  describe "retention" do
    it "expires a cursor from before the oldest row that is kept" do
      gone = message_event(topic: topic)
      message_event(topic: topic)
      kept = message_event(topic: topic)
      FeedEvent.where("id < ?", kept.id).delete_all

      expect { feed(since: cursor_at(gone.id)) }.to raise_error(described_class::Expired)
      expect(ids(feed(since: cursor_at(kept.id - 1)))).to eq([ kept.id ])
      expect(ids(feed(since: cursor_at(kept.id)))).to eq([])
    end

    it "does not expire a cursor on an empty table, or the one an empty table gave" do
      empty = feed.next_cursor
      expect(ids(feed(since: cursor_at(5)))).to eq([])

      first = message_event(topic: topic)
      expect(first.id).to be > 1
      expect(ids(feed(since: empty))).to eq([ first.id ])
    end

    it "expires a timestamp or a duration over 90 days" do
      message_event(topic: topic)

      expect { feed(since: 91.days.ago.utc.iso8601) }.to raise_error(described_class::Expired)
      expect { feed(since: "0000-01-01T00:00:00Z") }.to raise_error(described_class::Expired)
      expect { feed(since: "91d") }.to raise_error(Api::InvalidParameter, /90 days/)
      expect(feed(since: "90d").events.size).to eq(1)
      expect(feed(since: "2160h").events.size).to eq(1)
    end
  end

  describe "since" do
    it "rejects what is neither a cursor of the feed, a timestamp nor a duration" do
      list_cursor = Base64.urlsafe_encode64([ "abcdef12", 5 ].to_json, padding: false)
      bad = [ "yesterday", "7", "7w", "-1d", "1.5h", "2026-11-12", "2026-11-12T10:00:00", "2026-11-12 10:00:00Z",
              "2026-13-40T10:00:00Z", "!!!", list_cursor, Base64.urlsafe_encode64("[1,2]"),
              Base64.urlsafe_encode64([ described_class::SIGNATURE, "5" ].to_json),
              Base64.urlsafe_encode64([ described_class::SIGNATURE, -1 ].to_json),
              Base64.urlsafe_encode64([ described_class::SIGNATURE, 2**63 ].to_json),
              Base64.urlsafe_encode64([ described_class::SIGNATURE, 1, 2 ].to_json) ]

      bad.each do |value|
        expect { feed(since: value) }.to raise_error(Api::InvalidParameter, /since/), value
      end
    end

    it "never reads a cursor as a time or a duration" do
      [ 0, 1, 77, 10**6, 2**62 ].each do |id|
        cursor = cursor_at(id)
        expect(cursor).not_to match(described_class::DURATION)
        expect(cursor).not_to match(described_class::TIMESTAMP)
        expect(position(cursor)).to eq(id)
      end
    end

    it "takes the same position with any filter" do
      mine = message_event(topic: topic, sender: alice)
      cursor = feed(types: "ci.completed", author: "bob@example.org").next_cursor
      other = message_event(topic: topic, sender: bob)

      expect(position(cursor)).to eq(mine.id)
      expect(ids(feed(since: cursor))).to eq([ other.id ])
      expect(ids(feed(since: cursor, author: "alice.a@example.org"))).to eq([])
    end
  end

  describe "filters" do
    let(:other) { create(:topic, creator_alias: bob) }
    let!(:received) { message_event(topic: topic, sender: alice) }
    let!(:posted) { patchset_event(topic: other, sender: bob) }
    let(:row) { create(:patch_branch, topic: other, message: posted.message) }
    let!(:created) { recorded { FeedEvents::Recorder.branch_created(row) } }
    let!(:completed) { ci_event(row) }

    it "filters by types" do
      expect(ids(feed(types: "message.received"))).to eq([ received.id ])
      expect(ids(feed(types: "branch.created,ci.completed"))).to eq([ created.id, completed.id ])
      expect(ids(feed(types: "patchset.posted,patchset.posted"))).to eq([ posted.id ])
      [ "message", "message.received,", "message.received,nope", ",", "ci.completed, branch.created" ].each do |value|
        expect { feed(types: value) }.to raise_error(Api::InvalidParameter, /types/), value
      end
    end

    it "filters by the thread the message is in now" do
      expect(ids(feed(topic: other.id.to_s))).to eq([ posted.id, created.id, completed.id ])
      expect(ids(feed(topic: "999999999"))).to eq([])
      %w[abc 1.5 -1 12345678901234567890].each do |value|
        expect { feed(topic: value) }.to raise_error(Api::InvalidParameter, /topic/), value
      end

      received.message.update_columns(topic_id: other.id)
      expect(ids(feed(topic: other.id.to_s))).to eq([ received.id, posted.id, created.id, completed.id ])
      expect(ids(feed(topic: topic.id.to_s))).to eq([])
    end

    it "follows a merged thread to the one it was merged into" do
      target = create(:topic)
      other.update_columns(merged_into_topic_id: target.id)
      Message.where(topic_id: other.id).update_all(topic_id: target.id)

      expect(ids(feed(topic: other.id.to_s))).to eq([ posted.id, created.id, completed.id ])
      expect(ids(feed(topic: target.id.to_s))).to eq([ posted.id, created.id, completed.id ])
    end

    it "filters by the author, by any address of the person" do
      create(:alias, email: "bob.other@example.org", person: bob.person)

      expect(ids(feed(author: "bob.other@example.org"))).to eq([ posted.id, created.id, completed.id ])
      expect(ids(feed(author: "ALICE.A@example.org"))).to eq([ received.id ])
      expect(ids(feed(author: "nobody@example.org"))).to eq([])
      expect(position(feed(author: "nobody@example.org").next_cursor)).to eq(completed.id)
    end

    it "filters by list, and rejects one that does not exist" do
      hackers = create(:mailing_list, identifier: "pgsql-hackers")
      create(:mailing_list, identifier: "pgsql-bugs")
      create(:topic_mailing_list, topic: topic, mailing_list: hackers)

      expect(ids(feed(list: "pgsql-hackers"))).to eq([ received.id ])
      expect(ids(feed(list: "pgsql-bugs"))).to eq([])
      expect { feed(list: "pgsql-nope") }.to raise_error(Api::InvalidParameter, /list/)
    end

    it "filters by the stars and the threads of the user it is given, and no one else's" do
      user = create(:user, person: alice.person)
      stranger = create(:user)
      create(:topic_star, user: user, topic: other)
      create(:topic_star, user: stranger, topic: topic)

      expect(ids(feed(starred: true, user: user))).to eq([ posted.id, created.id, completed.id ])
      expect(ids(feed(participating: true, user: user))).to eq([ received.id ])
      expect(ids(feed(starred: true, participating: true, user: user))).to eq([])
      expect(ids(feed(starred: true, user: stranger))).to eq([ received.id ])
      expect(ids(feed(participating: true, user: stranger))).to eq([])
      expect(ids(feed(participating: true, user: create(:user, person: nil)))).to eq([])

      create(:message, topic: other, sender: alice)
      expect(ids(feed(starred: true, participating: true, user: user))).to eq([ posted.id, created.id, completed.id ])
    end

    it "combines the filters" do
      mine = message_event(topic: other, sender: alice)

      expect(ids(feed(topic: other.id.to_s, author: "alice.a@example.org"))).to eq([ mine.id ])
      expect(ids(feed(topic: other.id.to_s, types: "message.received,patchset.posted"))).to eq([ posted.id, mine.id ])
      expect(ids(feed(author: "bob@example.org", types: "ci.completed", since: cursor_at(created.id)))).to eq([ completed.id ])
    end
  end

  describe "ci_runs" do
    let(:row) { create(:patch_branch, topic: topic) }
    let!(:first) { ci_event(row, status: "success") }
    let!(:repeat) { ci_event(row, status: "success") }
    let!(:received) { message_event(topic: topic) }
    let!(:broken) { ci_event(row, status: "tests_failed") }
    let!(:again) { ci_event(row, status: "tests_failed") }

    it "leaves out the runs that repeat the verdict before them, by default" do
      expect(described_class::DEFAULT_CI_RUNS).to eq("changed")
      expect(ids(feed)).to eq([ first.id, received.id, broken.id ])
      expect(ids(feed(ci_runs: "changed"))).to eq([ first.id, received.id, broken.id ])
      expect(position(feed.next_cursor)).to eq(again.id)
    end

    it "gives every run when asked for all" do
      expect(ids(feed(ci_runs: "all"))).to eq([ first.id, repeat.id, received.id, broken.id, again.id ])
      expect(ids(feed(ci_runs: "all", types: "ci.completed", limit: "2"))).to eq([ first.id, repeat.id ])
    end

    it "follows the default" do
      stub_const("#{described_class}::DEFAULT_CI_RUNS", "all")
      expect(feed.events.size).to eq(5)
    end

    it "goes by what was recorded, not by what the runs say now" do
      PatchCiRun.where(id: repeat.patch_ci_run_id).update_all(status: "build_failed")
      expect(ids(feed)).to eq([ first.id, received.id, broken.id ])
    end

    it "gives a run that was recorded again" do
      run = PatchCiRun.find(again.patch_ci_run_id)
      run.update_columns(status: "success")
      replaced = recorded { FeedEvents::Recorder.ci_completed(run, replace: true) }

      expect(ids(feed)).to eq([ first.id, received.id, broken.id, replaced.id ])
      expect(FeedEvent.exists?(again.id)).to be(false)
    end

    it "pages over the runs it leaves out" do
      page = feed(limit: "2")
      expect(ids(page)).to eq([ first.id, received.id ])
      expect(page.has_more).to be(true)
      expect(ids(feed(since: page.next_cursor, limit: "2"))).to eq([ broken.id ])
    end

    it "rejects another value" do
      [ "", "none", "ALL", "changed,all" ].each do |value|
        expect { feed(ci_runs: value) }.to raise_error(Api::InvalidParameter, /ci_runs/), value.inspect
      end
    end
  end

  describe "what is left out" do
    it "leaves out threads that are only on hidden lists, unless a list is asked for" do
      hidden_list = create(:mailing_list, identifier: "pgsql-hidden", hidden_by_default: true)
      hidden = create(:topic, hidden_by_default: true)
      create(:topic_mailing_list, topic: hidden, mailing_list: hidden_list)
      shown = message_event(topic: topic)
      quiet = message_event(topic: hidden)
      branch_event(topic: hidden)

      page = feed
      expect(ids(page)).to eq([ shown.id ])
      expect(position(page.next_cursor)).to eq(FeedEvent.maximum(:id))
      expect(ids(feed(list: "pgsql-hidden")).first).to eq(quiet.id)
      expect(feed(list: "pgsql-hidden").events.size).to eq(2)
      expect(ids(feed(topic: hidden.id.to_s))).to eq([])
    end

    it "leaves out lineage-only branches and their runs" do
      real = create(:patch_branch, topic: topic)
      created = recorded { FeedEvents::Recorder.branch_created(real) }
      completed = ci_event(real)
      expect(ids(feed)).to eq([ created.id, completed.id ])

      real.update_columns(lineage_only: true)
      expect(ids(feed)).to eq([])
    end

    it "leaves out a patchset that is one no more" do
      posted = patchset_event(topic: topic)
      expect(ids(feed)).to eq([ posted.id ])

      posted.message.update_columns(is_patch_submission: false)
      expect(ids(feed)).to eq([])
    end

    it "leaves out events whose record is gone" do
      received = message_event(topic: topic)
      branch = create(:patch_branch, topic: topic)
      recorded { FeedEvents::Recorder.branch_created(branch) }
      ci_event(branch)
      orphan = FeedEvent.create!(event_type: "message.received", occurred_at: 1.hour.ago, created_at: 1.minute.ago)
      loose = FeedEvent.create!(event_type: "ci.completed", occurred_at: 1.hour.ago, created_at: 1.minute.ago,
                                message_id: received.message_id, patch_branch_id: nil, patch_ci_run_id: nil)
      branch.destroy!

      page = feed
      expect(ids(page)).to eq([ received.id ])
      expect(position(page.next_cursor)).to eq(loose.id)
      expect(orphan.id).to be < loose.id
    end
  end

  describe "limit" do
    it "defaults to 50, lowers a larger one to 200 and rejects what is not a positive integer" do
      expect(described_class.new.limit).to eq(50)
      expect(described_class.new(limit: "500").limit).to eq(200)
      %w[0 -1 abc 1.5].each do |value|
        expect { described_class.new(limit: value) }.to raise_error(Api::CursorPaginator::InvalidLimit), value
      end
    end
  end
end
