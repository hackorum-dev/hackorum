# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Search Integration', type: :service do
  let(:person) { create(:person) }
  let(:user) { create(:user, person: person) }

  def search(query_string, user: nil)
    parser = Search::QueryParser.new
    ast = parser.parse(query_string)
    validator = Search::QueryValidator.new(ast)
    validated = validator.validate
    builder = Search::QueryBuilder.new(ast: validated.ast, user: user)
    result = builder.build

    {
      topics: result.relation.to_a,
      warnings: validated.warnings + result.warnings
    }
  end

  describe 'end-to-end query processing' do
    let!(:postgresql_topic) do
      topic = create(:topic, title: 'PostgreSQL Performance Guide')
      create(:message, topic: topic, body: 'Tips for optimizing PostgreSQL queries')
      topic.update_denormalized_counts!
      topic
    end

    let!(:mysql_topic) do
      topic = create(:topic, title: 'MySQL vs PostgreSQL')
      create(:message, topic: topic, body: 'Comparison of database systems')
      topic.update_denormalized_counts!
      topic
    end

    it 'finds topics by title keyword' do
      result = search('performance', user: user)
      expect(result[:topics]).to include(postgresql_topic)
      expect(result[:topics]).not_to include(mysql_topic)
    end

    it 'finds topics by body keyword' do
      result = search('optimizing', user: user)
      expect(result[:topics]).to include(postgresql_topic)
    end

    it 'handles complex queries with multiple conditions' do
      result = search('postgresql -mysql', user: user)
      expect(result[:topics]).to include(postgresql_topic)
      # mysql_topic has "PostgreSQL" in title too
    end
  end

  describe 'author-based queries' do
    let(:john_person) { create(:person) }
    let(:john_alias) { create(:alias, name: 'John Smith', email: 'john@postgresql.org', person: john_person) }

    let!(:topic_from_john) do
      topic = create(:topic, title: 'RFC: New Feature')
      create(:message, topic: topic, sender: john_alias, sender_person_id: john_person.id)
      topic.update_denormalized_counts!
      topic
    end

    let!(:topic_not_from_john) do
      topic = create(:topic, title: 'Another Discussion')
      create(:message, topic: topic)
      topic.update_denormalized_counts!
      topic
    end

    it 'finds topics by author name' do
      result = search('from:john', user: user)
      expect(result[:topics]).to include(topic_from_john)
      expect(result[:topics]).not_to include(topic_not_from_john)
    end

    it 'finds topics by author email' do
      result = search('from:john@postgresql.org', user: user)
      expect(result[:topics]).to include(topic_from_john)
    end

    it 'finds topics with OR between authors' do
      jane_person = create(:person)
      jane_alias = create(:alias, name: 'Jane Doe', person: jane_person)
      topic_from_jane = create(:topic, title: 'Jane Topic')
      create(:message, topic: topic_from_jane, sender: jane_alias, sender_person_id: jane_person.id)
      topic_from_jane.update_denormalized_counts!

      result = search('from:john OR from:jane', user: user)
      expect(result[:topics]).to include(topic_from_john, topic_from_jane)
      expect(result[:topics]).not_to include(topic_not_from_john)
    end
  end

  describe 'date-based queries' do
    let!(:recent_topic) do
      topic = create(:topic, title: 'Recent Topic', created_at: 3.days.ago)
      create(:message, topic: topic, created_at: 3.days.ago)
      topic.update_denormalized_counts!
      topic
    end

    let!(:old_topic) do
      topic = create(:topic, title: 'Old Topic', created_at: 3.months.ago)
      create(:message, topic: topic, created_at: 3.months.ago)
      topic.update_denormalized_counts!
      topic
    end

    it 'finds recent topics with first_after' do
      result = search('first_after:1w', user: user)
      expect(result[:topics]).to include(recent_topic)
      expect(result[:topics]).not_to include(old_topic)
    end

    it 'finds old topics with first_before' do
      result = search('first_before:1m', user: user)
      expect(result[:topics]).to include(old_topic)
      expect(result[:topics]).not_to include(recent_topic)
    end

    it 'combines date range' do
      result = search('first_after:6m first_before:1w', user: user)
      expect(result[:topics]).to include(old_topic)
      expect(result[:topics]).not_to include(recent_topic)
    end
  end

  describe 'state-based queries' do
    let!(:starred_topic) do
      topic = create(:topic, title: 'Starred Topic')
      create(:message, topic: topic)
      create(:topic_star, user: user, topic: topic)
      topic.update_denormalized_counts!
      topic
    end

    let!(:unstarred_topic) do
      topic = create(:topic, title: 'Unstarred Topic')
      create(:message, topic: topic)
      topic.update_denormalized_counts!
      topic
    end

    it 'finds starred topics' do
      result = search('starred:me', user: user)
      expect(result[:topics]).to include(starred_topic)
      expect(result[:topics]).not_to include(unstarred_topic)
    end

    it 'finds topics with notes' do
      topic_with_note = create(:topic, title: 'Topic with Note')
      create(:message, topic: topic_with_note)
      create(:note, topic: topic_with_note, author: user)
      topic_with_note.update_denormalized_counts!

      result = search('notes:me', user: user)
      expect(result[:topics]).to include(topic_with_note)
      expect(result[:topics]).not_to include(starred_topic)
    end
  end

  describe 'count-based queries' do
    let!(:active_topic) do
      topic = create(:topic, title: 'Active Discussion', message_count: 25, participant_count: 8)
      topic
    end

    let!(:quiet_topic) do
      topic = create(:topic, title: 'Quiet Topic', message_count: 2, participant_count: 1)
      topic
    end

    it 'finds topics with many messages' do
      result = search('messages:>10', user: user)
      expect(result[:topics]).to include(active_topic)
      expect(result[:topics]).not_to include(quiet_topic)
    end

    it 'finds topics with few participants' do
      result = search('participants:<3', user: user)
      expect(result[:topics]).to include(quiet_topic)
      expect(result[:topics]).not_to include(active_topic)
    end

    it 'combines count with text search' do
      result = search('active messages:>10', user: user)
      expect(result[:topics]).to include(active_topic)
    end
  end

  describe 'presence-based queries' do
    let!(:topic_with_patch) do
      topic = create(:topic, title: 'Patch Topic')
      msg = create(:message, topic: topic)
      create(:attachment, message: msg, file_name: 'feature.patch')
      topic.update_denormalized_counts!
      topic
    end

    let!(:topic_without_patch) do
      topic = create(:topic, title: 'Discussion Topic')
      create(:message, topic: topic)
      topic.update_denormalized_counts!
      topic
    end

    it 'finds topics with patches' do
      result = search('has:patch', user: user)
      expect(result[:topics]).to include(topic_with_patch)
      expect(result[:topics]).not_to include(topic_without_patch)
    end

    it 'finds topics without patches' do
      result = search('-has:patch', user: user)
      expect(result[:topics]).to include(topic_without_patch)
      expect(result[:topics]).not_to include(topic_with_patch)
    end
  end

  describe 'error handling' do
    it 'returns warnings for empty selectors' do
      result = search('from: title:test', user: user)
      expect(result[:warnings]).to include(/empty value/i)
    end

    it 'returns warnings for invalid dates' do
      result = search('first_after:notadate', user: user)
      expect(result[:warnings]).to include(/invalid date/i)
    end

    it 'returns warnings for invalid counts' do
      result = search('messages:abc', user: user)
      expect(result[:warnings]).to include(/invalid count/i)
    end
  end
end
