# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Search negation", type: :service do
  let(:user) { create(:user, person: create(:person)) }
  let(:teammate) { create(:user, person: create(:person)) }
  let(:team) { create(:team, name: "reviewers") }
  let(:john) { create(:person) }
  let(:john_alias) { create(:alias, name: "John Doe", email: "john@example.com", person: john) }
  let(:list) { create(:mailing_list, identifier: "pgsql-bugs", display_name: "bugs") }

  def topic_with(title, messages: 1, **message_attrs)
    topic = create(:topic, title: title)
    msgs = create_list(:message, messages, topic: topic, **message_attrs)
    topic.update_denormalized_counts!
    [ topic.reload, msgs ]
  end

  def mark_read(reader, topic, upto)
    MessageReadRange.create!(user: reader, topic: topic, range_start_message_id: upto.id,
                             range_end_message_id: upto.id, read_at: Time.current)
  end

  let!(:read) { topic_with("Read") }
  let!(:partial) { topic_with("Partial", messages: 2) }
  let!(:aware) { topic_with("Aware") }
  let!(:fresh) { topic_with("Fresh") }
  let!(:johns) { topic_with("Johns", sender: john_alias, sender_person_id: john.id, body: "zebra crossing") }

  let(:all_titles) { %w[Read Partial Aware Fresh Johns] }

  before do
    create(:team_member, team: team, user: user)
    create(:team_member, team: team, user: teammate)

    mark_read(user, read.first, read.last.last)
    mark_read(user, partial.first, partial.last.first)
    mark_read(teammate, partial.first, partial.last.last)
    ThreadAwareness.create!(user: user, topic: aware.first, aware_until_message_id: aware.last.last.id,
                            aware_at: Time.current)

    create(:topic_star, user: user, topic: read.first)
    create(:note, topic: partial.first, author: user)
    create(:attachment, message: aware.last.first, file_name: "fix.patch")
    MessageMailingList.create!(message: fresh.last.first, mailing_list: list)
    fresh.first.update_denormalized_counts!
  end

  def relation(query)
    validated = Search::QueryValidator.new(Search::QueryParser.new.parse(query)).validate
    Search::QueryBuilder.new(ast: validated.ast, user: user).build.relation
  end

  def titles(query)
    relation(query).pluck(:title).sort
  end

  {
    "-from:john" => %w[Johns],
    "-body:zebra" => %w[Johns],
    "-zebra" => %w[Johns],
    "-starred:me" => %w[Read],
    "-notes:me" => %w[Partial],
    "-list:bugs" => %w[Fresh],
    "-has:attachment" => %w[Aware],
    "-has:attachment[name:fix]" => %w[Aware],
    "-(from:john OR starred:me)" => %w[Johns Read],
    "-(-from:john -starred:me)" => %w[Aware Fresh Partial],
    "-unread:me" => %w[Aware Fresh Johns Partial],
    "-read:me" => %w[Read],
    "-reading:me" => %w[Partial],
    "-new:me" => %w[Fresh Johns],
    "-unread:reviewers" => %w[Aware Fresh Johns],
    "-read:reviewers" => %w[Partial Read],
    "-reading:reviewers" => [],
    "-new:reviewers" => %w[Fresh Johns]
  }.each do |query, excluded|
    it "#{query} leaves out #{excluded.join(', ').presence || 'nothing'}" do
      expect(titles(query)).to eq((all_titles - excluded).sort)
    end
  end

  it "unread:<team> is what no member has read to the end" do
    expect(titles("unread:reviewers")).to eq(%w[Aware Fresh Johns])
  end

  it "new:<team> is what no member has seen" do
    expect(titles("new:reviewers")).to eq(%w[Fresh Johns])
  end

  it "keeps ignored topics out of -ignored:me" do
    create(:topic_ignore, user: user, topic: fresh.first)
    expect(titles("-ignored:me")).to eq((all_titles - %w[Fresh]).sort)
  end

  # NOT IN (subquery) is rescanned for every topic once the subquery result
  # outgrows work_mem. The user's own ignore list is the one exception left.
  describe "generated SQL" do
    queries = %w[
      -from:john -from:john[messages:>1] -from:john[body:zebra] -zebra -body:zebra
      -unread:me -read:me -reading:me -new:me
      unread:reviewers -unread:reviewers -read:reviewers -reading:reviewers new:reviewers -new:reviewers
      -starred:me -ignored:me -notes:me -tag:todo
      -has:attachment -has:patch -has:committer -has:core_team -has:commitfest
      -has:attachment[name:fix] -messages_after:2024-01-01 -messages_before:2024-01-01
      -commitfest:PG19-1 -list:bugs
    ] + [ "-(from:john OR starred:me)", "-(from:john zebra)" ]

    it "text search has no IN subquery beside the title match" do
      expect(relation("zebra").to_sql).not_to match(/ OR topics\.id IN \(SELECT "messages"/i)
      expect(titles("zebra")).to eq(%w[Johns])
      expect(titles(%q("zebra crossing"))).to eq(%w[Johns])
      expect(titles(%q(-"zebra crossing"))).to eq(all_titles.sort - %w[Johns])
    end

    queries.each do |query|
      it "#{query} has no NOT IN subquery" do
        sql = relation(query).to_sql
        expect(sql).not_to match(/NOT IN \((?!SELECT topic_id FROM topic_ignores)|NOT \(topics\.id IN/i)
        expect { relation(query).load }.not_to raise_error
      end
    end
  end
end
