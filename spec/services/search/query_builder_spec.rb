# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Search::QueryBuilder, type: :service do
  let(:person) { create(:person) }
  let(:user) { create(:user, person: person) }
  let(:parser) { Search::QueryParser.new }

  def build_query(query_string)
    ast = parser.parse(query_string)
    validated = Search::QueryValidator.new(ast).validate
    described_class.new(ast: validated.ast, user: user).build
  end

  describe '#build' do
    describe 'text search' do
      let!(:topic_with_title) { create(:topic, title: 'PostgreSQL Performance Tuning') }
      let!(:topic_other) { create(:topic, title: 'Unrelated Topic') }

      before do
        create(:message, topic: topic_with_title, body: 'Some content')
        create(:message, topic: topic_other, body: 'Different content')
        topic_with_title.update_denormalized_counts!
        topic_other.update_denormalized_counts!
      end

      it 'searches in title' do
        result = build_query('postgresql')
        expect(result.relation).to include(topic_with_title)
        expect(result.relation).not_to include(topic_other)
      end

      it 'searches in body' do
        topic_body = create(:topic, title: 'Different')
        create(:message, topic: topic_body, body: 'postgresql optimization tips')
        topic_body.update_denormalized_counts!

        result = build_query('optimization')
        expect(result.relation).to include(topic_body)
      end

      context 'phrase matching with quotes' do
        let!(:topic_phrase) { create(:topic, title: 'Shared Buffers Configuration') }
        let!(:topic_words_apart) { create(:topic, title: 'Shared memory and ring Buffers') }

        before do
          create(:message, topic: topic_phrase, body: 'content about shared buffers')
          create(:message, topic: topic_words_apart, body: 'shared data with multiple buffers')
          topic_phrase.update_denormalized_counts!
          topic_words_apart.update_denormalized_counts!
        end

        it 'matches phrase exactly when quoted' do
          result = build_query('"shared buffers"')
          topic_ids = result.relation.pluck(:id)
          # Only topic_phrase has "shared buffers" as adjacent words
          expect(topic_ids).to include(topic_phrase.id)
          expect(topic_ids).not_to include(topic_words_apart.id)
        end

        it 'matches words anywhere when unquoted' do
          result = build_query('shared buffers')
          topic_ids = result.relation.pluck(:id)
          # Both topics contain both words (though not adjacent in topic_words_apart)
          expect(topic_ids).to include(topic_phrase.id)
          expect(topic_ids).to include(topic_words_apart.id)
        end

        it 'supports phrase matching in title: selector' do
          result = build_query('title:"shared buffers"')
          topic_ids = result.relation.pluck(:id)
          expect(topic_ids).to include(topic_phrase.id)
          expect(topic_ids).not_to include(topic_words_apart.id)
        end

        it 'supports phrase matching in body: selector' do
          topic_body_phrase = create(:topic, title: 'Other Topic')
          create(:message, topic: topic_body_phrase, body: 'discussing shared buffers settings')
          topic_body_phrase.update_denormalized_counts!

          topic_body_apart = create(:topic, title: 'Another Topic')
          create(:message, topic: topic_body_apart, body: 'shared settings for buffers')
          topic_body_apart.update_denormalized_counts!

          result = build_query('body:"shared buffers"')
          topic_ids = result.relation.pluck(:id)
          expect(topic_ids).to include(topic_body_phrase.id)
          expect(topic_ids).not_to include(topic_body_apart.id)
        end
      end
    end

    describe 'from: selector' do
      let(:john_person) { create(:person) }
      let(:john_alias) { create(:alias, name: 'John Doe', email: 'john@example.com', person: john_person) }
      let!(:topic_from_john) { create(:topic, title: 'Topic from John') }

      before do
        create(:message, topic: topic_from_john, sender: john_alias, sender_person_id: john_person.id)
        topic_from_john.update_denormalized_counts!
      end

      it 'filters by author name' do
        result = build_query('from:john')
        expect(result.relation).to include(topic_from_john)
      end

      it 'filters by author email' do
        result = build_query('from:john@example.com')
        expect(result.relation).to include(topic_from_john)
      end

      it 'filters by from:me' do
        my_alias = create(:alias, person: person)
        my_topic = create(:topic, title: 'My Topic')
        create(:message, topic: my_topic, sender: my_alias, sender_person_id: person.id)
        my_topic.update_denormalized_counts!

        result = build_query('from:me')
        expect(result.relation).to include(my_topic)
        expect(result.relation).not_to include(topic_from_john)
      end
    end

    describe 'starter: selector' do
      let!(:topic) { create(:topic, creator_person_id: person.id) }
      let!(:other_topic) { create(:topic) }

      it 'filters by topic creator' do
        result = build_query('starter:me')
        expect(result.relation).to include(topic)
        expect(result.relation).not_to include(other_topic)
      end
    end

    describe 'date selectors' do
      let!(:recent_topic) { create(:topic, created_at: 2.days.ago) }
      let!(:old_topic) { create(:topic, created_at: 2.months.ago) }

      before do
        create(:message, topic: recent_topic, created_at: 2.days.ago)
        create(:message, topic: old_topic, created_at: 2.months.ago)
        recent_topic.update_denormalized_counts!
        old_topic.update_denormalized_counts!
      end

      it 'filters by first_after' do
        result = build_query('first_after:1w')
        expect(result.relation).to include(recent_topic)
        expect(result.relation).not_to include(old_topic)
      end

      it 'filters by first_before' do
        result = build_query('first_before:1w')
        expect(result.relation).to include(old_topic)
        expect(result.relation).not_to include(recent_topic)
      end

      it 'filters by last_after using last_message_at' do
        result = build_query('last_after:1w')
        expect(result.relation).to include(recent_topic)
        expect(result.relation).not_to include(old_topic)
      end
    end

    describe 'count selectors' do
      let!(:large_topic) { create(:topic, message_count: 15, participant_count: 5) }
      let!(:small_topic) { create(:topic, message_count: 2, participant_count: 1) }

      it 'filters by messages:>N' do
        result = build_query('messages:>10')
        expect(result.relation).to include(large_topic)
        expect(result.relation).not_to include(small_topic)
      end

      it 'filters by messages:<N' do
        result = build_query('messages:<5')
        expect(result.relation).to include(small_topic)
        expect(result.relation).not_to include(large_topic)
      end

      it 'filters by participants:>N' do
        result = build_query('participants:>3')
        expect(result.relation).to include(large_topic)
        expect(result.relation).not_to include(small_topic)
      end

      it 'filters by exact count' do
        result = build_query('messages:2')
        expect(result.relation).to include(small_topic)
        expect(result.relation).not_to include(large_topic)
      end
    end

    describe 'has: selector' do
      describe 'has:attachment' do
        let!(:topic_with_attachment) { create(:topic) }
        let!(:topic_without_attachment) { create(:topic) }

        before do
          msg_with = create(:message, topic: topic_with_attachment)
          create(:attachment, message: msg_with)
          create(:message, topic: topic_without_attachment)
        end

        it 'filters topics with attachments' do
          result = build_query('has:attachment')
          expect(result.relation).to include(topic_with_attachment)
          expect(result.relation).not_to include(topic_without_attachment)
        end
      end

      describe 'has:patch' do
        let!(:topic_with_patch) { create(:topic) }
        let!(:topic_without_patch) { create(:topic) }

        before do
          msg = create(:message, topic: topic_with_patch)
          create(:attachment, message: msg, file_name: 'feature.patch')
          msg2 = create(:message, topic: topic_without_patch)
          create(:attachment, message: msg2, file_name: 'document.pdf')
        end

        it 'filters topics with patch files' do
          result = build_query('has:patch')
          expect(result.relation).to include(topic_with_patch)
          expect(result.relation).not_to include(topic_without_patch)
        end
      end

      describe 'has:contributor' do
        let!(:topic_with_contributor) { create(:topic, contributor_participant_count: 2) }
        let!(:topic_without_contributor) { create(:topic, contributor_participant_count: 0) }

        it 'filters topics with contributor participation' do
          result = build_query('has:contributor')
          expect(result.relation).to include(topic_with_contributor)
          expect(result.relation).not_to include(topic_without_contributor)
        end
      end
    end

    describe 'state selectors' do
      describe 'starred:me' do
        let!(:starred_topic) { create(:topic) }
        let!(:unstarred_topic) { create(:topic) }

        before do
          create(:topic_star, user: user, topic: starred_topic)
        end

        it 'filters starred topics' do
          result = build_query('starred:me')
          expect(result.relation).to include(starred_topic)
          expect(result.relation).not_to include(unstarred_topic)
        end
      end

      describe 'notes:me' do
        let!(:topic_with_note) { create(:topic) }
        let!(:topic_without_note) { create(:topic) }

        before do
          create(:note, topic: topic_with_note, author: user)
        end

        it 'filters topics with notes' do
          result = build_query('notes:me')
          expect(result.relation).to include(topic_with_note)
          expect(result.relation).not_to include(topic_without_note)
        end
      end

      describe 'tag: selector' do
        let!(:topic_tagged) { create(:topic) }
        let!(:topic_untagged) { create(:topic) }
        let!(:note_with_tag) { create(:note, topic: topic_tagged, author: user) }

        before do
          create(:note_tag, note: note_with_tag, tag: 'important')
        end

        it 'filters topics with specific tag from current user' do
          result = build_query('tag:important[from:me]')
          expect(result.relation).to include(topic_tagged)
          expect(result.relation).not_to include(topic_untagged)
        end

        it 'filters topics with any tag from current user' do
          result = build_query('tag:[from:me]')
          expect(result.relation).to include(topic_tagged)
          expect(result.relation).not_to include(topic_untagged)
        end

        it 'filters topics with specific tag from any accessible source' do
          result = build_query('tag:important')
          expect(result.relation).to include(topic_tagged)
          expect(result.relation).not_to include(topic_untagged)
        end

        it 'excludes topics with tag when negated' do
          result = build_query('-tag:important')
          expect(result.relation).not_to include(topic_tagged)
          expect(result.relation).to include(topic_untagged)
        end

        it 'is case-insensitive for tag names' do
          result = build_query('tag:IMPORTANT[from:me]')
          expect(result.relation).to include(topic_tagged)
        end

        context 'with team tags' do
          let(:team) { create(:team, name: 'reviewers', visibility: :visible) }
          let(:teammate) { create(:user, person: create(:person)) }
          let!(:topic_tagged_by_teammate) { create(:topic) }
          let!(:topic_not_tagged_by_team) { create(:topic) }
          let!(:teammate_note) { create(:note, topic: topic_tagged_by_teammate, author: teammate) }

          before do
            create(:team_member, team: team, user: user)
            create(:team_member, team: team, user: teammate)
            create(:note_mention, note: teammate_note, mentionable: team)
            create(:note_tag, note: teammate_note, tag: 'review-needed')
          end

          it 'filters topics with tag from team members' do
            result = build_query('tag:review-needed[from:reviewers]')
            expect(result.relation).to include(topic_tagged_by_teammate)
            # topic_tagged has 'important' tag, not 'review-needed'
            expect(result.relation).not_to include(topic_tagged)
          end

          it 'filters topics with any tag from team members' do
            result = build_query('tag:[from:reviewers]')
            # Both topics with tags from team members are included
            # (user is a team member, so topic_tagged is included too)
            expect(result.relation).to include(topic_tagged_by_teammate)
            expect(result.relation).to include(topic_tagged)
            # Topic with no team member tags should be excluded
            expect(result.relation).not_to include(topic_not_tagged_by_team)
          end
        end

        context 'when not signed in' do
          it 'returns empty result with warning' do
            ast = parser.parse('tag:important')
            validated = Search::QueryValidator.new(ast).validate
            result = described_class.new(ast: validated.ast, user: nil).build
            expect(result.relation.count).to eq(0)
          end
        end
      end

      describe 'commitfest: selector' do
        let!(:tag) { create(:commitfest_tag) }
        let!(:commitfest_first) { create(:commitfest, name: 'PGX-Final') }
        let!(:commitfest_second) { create(:commitfest) }
        let!(:topic_first) { create(:topic) }
        let!(:topic_second) { create(:topic) }

        let!(:patch_first) { create(:commitfest_patch, :with_topic, :with_commitfest, :with_tag, topic: topic_first, commitfest: commitfest_first, commitfest_tag: tag) }
        let!(:patch_second) { create(:commitfest_patch, :with_topic, topic: topic_second) }

        before do
          create(:commitfest_patch_commitfest, commitfest: commitfest_second, commitfest_patch: patch_second, status: 'Commited')
        end

        it 'filters topics with specific commitfest name' do
          result = build_query('commitfest:PGX-Final')
          expect(result.relation).to include(topic_first)
          expect(result.relation).not_to include(topic_second)
        end

        it 'filters topics with specific commitfest name from condition' do
          result = build_query('commitfest:[name:PGX-Final]')
          expect(result.relation).to include(topic_first)
          expect(result.relation).not_to include(topic_second)
        end

        it 'filters topics with specific commitfest status' do
          result = build_query('commitfest:[status:commited]')
          expect(result.relation).to include(topic_second)
          expect(result.relation).not_to include(topic_first)
        end

        it 'filters topics with specific commitfest tag' do
          result = build_query('commitfest:[tag:bugfix]')
          expect(result.relation).to include(topic_first)
          expect(result.relation).not_to include(topic_second)
        end
      end
    end

    describe 'negation' do
      let!(:topic) { create(:topic, title: 'PostgreSQL Feature') }
      let!(:other_topic) { create(:topic, title: 'Unrelated Discussion') }

      before do
        create(:message, topic: topic, body: 'PostgreSQL content')
        create(:message, topic: other_topic, body: 'Different content')
        topic.update_denormalized_counts!
        other_topic.update_denormalized_counts!
      end

      it 'negates text search' do
        result = build_query('-postgresql')
        topic_ids = result.relation.pluck(:id)
        expect(topic_ids).not_to include(topic.id)
        # other_topic should be included (doesn't match 'postgresql')
        expect(topic_ids).to include(other_topic.id)
      end

      it 'negates has: selector' do
        topic.update!(contributor_participant_count: 1)
        other_topic.update!(contributor_participant_count: 0)
        result = build_query('-has:contributor')
        topic_ids = result.relation.pluck(:id)
        expect(topic_ids).not_to include(topic.id)
        expect(topic_ids).to include(other_topic.id)
      end

      it 'negates grouped OR expression' do
        # topic matches 'postgresql' (title: 'PostgreSQL Feature')
        # other_topic title is 'Unrelated Discussion' - matches 'unrelated'!
        # Create a topic that matches neither
        clean_topic = create(:topic, title: 'Clean Topic')
        create(:message, topic: clean_topic, body: 'nothing special here')
        clean_topic.update_denormalized_counts!

        result = build_query('-(postgresql OR unrelated)')
        topic_ids = result.relation.pluck(:id)
        # topic matches 'postgresql' - should be excluded
        expect(topic_ids).not_to include(topic.id)
        # other_topic matches 'unrelated' - should be excluded
        expect(topic_ids).not_to include(other_topic.id)
        # clean_topic matches neither - should be included
        expect(topic_ids).to include(clean_topic.id)
      end

      it 'negates grouped AND expression' do
        # Create a topic that matches both terms
        topic_both = create(:topic, title: 'PostgreSQL Performance Guide')
        create(:message, topic: topic_both, body: 'performance tuning tips')
        topic_both.update_denormalized_counts!

        result = build_query('-(postgresql performance)')
        topic_ids = result.relation.pluck(:id)
        # topic_both matches both 'postgresql' AND 'performance' - should be excluded
        expect(topic_ids).not_to include(topic_both.id)
        # topic matches 'postgresql' but not 'performance' - should be included
        expect(topic_ids).to include(topic.id)
        expect(topic_ids).to include(other_topic.id)
      end

      it 'negates grouped expression with selectors' do
        tom_person = create(:person)
        tom_alias = create(:alias, name: 'Tom Lane', email: 'tom@example.com', person: tom_person)
        bruce_person = create(:person)
        bruce_alias = create(:alias, name: 'Bruce Momjian', email: 'bruce@example.com', person: bruce_person)

        topic_from_tom = create(:topic, title: 'Tom Topic')
        create(:message, topic: topic_from_tom, sender: tom_alias, sender_person_id: tom_person.id)
        topic_from_tom.update_denormalized_counts!

        topic_from_bruce = create(:topic, title: 'Bruce Topic')
        create(:message, topic: topic_from_bruce, sender: bruce_alias, sender_person_id: bruce_person.id)
        topic_from_bruce.update_denormalized_counts!

        result = build_query('-(from:tom OR from:bruce)')
        topic_ids = result.relation.pluck(:id)
        expect(topic_ids).not_to include(topic_from_tom.id)
        expect(topic_ids).not_to include(topic_from_bruce.id)
        expect(topic_ids).to include(topic.id)
        expect(topic_ids).to include(other_topic.id)
      end
    end

    describe 'boolean operators' do
      let!(:topic1) { create(:topic, title: 'PostgreSQL Database Guide') }
      let!(:topic2) { create(:topic, title: 'MySQL Administration Tips') }
      let!(:topic3) { create(:topic, title: 'Oracle DBA Handbook') }

      before do
        [ topic1, topic2, topic3 ].each do |t|
          create(:message, topic: t, body: 'Some content')
          t.update_denormalized_counts!
        end
      end

      it 'handles OR' do
        result = build_query('postgresql OR mysql')
        topic_ids = result.relation.pluck(:id)
        expect(topic_ids).to include(topic1.id, topic2.id)
        expect(topic_ids).not_to include(topic3.id)
      end

      it 'handles implicit AND' do
        topic_both = create(:topic, title: 'PostgreSQL and MySQL Comparison Guide')
        create(:message, topic: topic_both, body: 'detailed comparison')
        topic_both.update_denormalized_counts!

        result = build_query('postgresql comparison')
        topic_ids = result.relation.pluck(:id)
        expect(topic_ids).to include(topic_both.id)
        # topic1 has postgresql but not comparison
        expect(topic_ids).not_to include(topic1.id)
      end
    end

    describe 'with nil AST' do
      it 'returns empty relation' do
        result = described_class.new(ast: nil, user: user).build
        expect(result.relation.count).to eq(0)
        expect(result.warnings).to be_empty
      end
    end

    describe 'dependent conditions' do
      describe 'from: with conditions' do
        let(:bruce_person) { create(:person) }
        let(:bruce_alias) { create(:alias, name: 'Bruce Momjian', email: 'bruce@postgresql.org', person: bruce_person) }
        let(:tom_person) { create(:person) }
        let(:tom_alias) { create(:alias, name: 'Tom Lane', email: 'tom@postgresql.org', person: tom_person) }

        let!(:topic_bruce_10_msgs) { create(:topic, title: 'Bruce Discussion') }
        let!(:topic_bruce_2_msgs) { create(:topic, title: 'Bruce Quick Question') }
        let!(:topic_tom_many_msgs) { create(:topic, title: 'Tom Discussion') }

        before do
          # Bruce posts 10 messages in first topic
          10.times do
            create(:message, topic: topic_bruce_10_msgs, sender: bruce_alias, sender_person_id: bruce_person.id)
          end
          topic_bruce_10_msgs.update_denormalized_counts!

          # Bruce posts 2 messages in second topic
          2.times do
            create(:message, topic: topic_bruce_2_msgs, sender: bruce_alias, sender_person_id: bruce_person.id)
          end
          topic_bruce_2_msgs.update_denormalized_counts!

          # Tom posts many messages
          15.times do
            create(:message, topic: topic_tom_many_msgs, sender: tom_alias, sender_person_id: tom_person.id)
          end
          topic_tom_many_msgs.update_denormalized_counts!

          # Create/update topic_participants records (use update_all to ensure values are set correctly)
          tp1 = TopicParticipant.find_or_create_by!(topic: topic_bruce_10_msgs, person: bruce_person) do |tp|
            tp.first_message_at = 2.weeks.ago
            tp.last_message_at = 1.week.ago
          end
          tp1.update!(message_count: 10, first_message_at: 2.weeks.ago, last_message_at: 1.week.ago)

          tp2 = TopicParticipant.find_or_create_by!(topic: topic_bruce_2_msgs, person: bruce_person) do |tp|
            tp.first_message_at = 1.day.ago
            tp.last_message_at = 1.day.ago
          end
          tp2.update!(message_count: 2, first_message_at: 1.day.ago, last_message_at: 1.day.ago)

          tp3 = TopicParticipant.find_or_create_by!(topic: topic_tom_many_msgs, person: tom_person) do |tp|
            tp.first_message_at = 3.months.ago
            tp.last_message_at = 2.months.ago
          end
          tp3.update!(message_count: 15, first_message_at: 3.months.ago, last_message_at: 2.months.ago)
        end

        it 'filters by message count condition' do
          result = build_query('from:bruce[messages:>=10]')
          expect(result.relation).to include(topic_bruce_10_msgs)
          expect(result.relation).not_to include(topic_bruce_2_msgs)
          expect(result.relation).not_to include(topic_tom_many_msgs)
        end

        it 'filters by message count with less than condition' do
          result = build_query('from:bruce[messages:<5]')
          expect(result.relation).to include(topic_bruce_2_msgs)
          expect(result.relation).not_to include(topic_bruce_10_msgs)
        end

        it 'filters by last_before condition' do
          result = build_query('from:tom[last_before:1m]')
          expect(result.relation).to include(topic_tom_many_msgs)
          expect(result.relation).not_to include(topic_bruce_10_msgs)
          expect(result.relation).not_to include(topic_bruce_2_msgs)
        end

        it 'filters by last_after condition' do
          # topic_bruce_10_msgs: last_message_at = 1.week.ago
          # topic_bruce_2_msgs: last_message_at = 1.day.ago
          # Using 3d threshold: only 1.day.ago matches (is after 3 days ago)
          result = build_query('from:bruce[last_after:3d]')
          expect(result.relation).to include(topic_bruce_2_msgs)
          expect(result.relation).not_to include(topic_bruce_10_msgs)
        end

        it 'combines multiple conditions' do
          # Both topics have messages:>=2, but only topic_bruce_2_msgs was active within 3 days
          result = build_query('from:bruce[messages:>=2, last_after:3d]')
          expect(result.relation).to include(topic_bruce_2_msgs)
          expect(result.relation).not_to include(topic_bruce_10_msgs)
        end

        it 'supports negation with conditions' do
          result = build_query('-from:bruce[messages:>=10]')
          expect(result.relation).not_to include(topic_bruce_10_msgs)
          expect(result.relation).to include(topic_bruce_2_msgs)
          expect(result.relation).to include(topic_tom_many_msgs)
        end
      end

      describe 'from: with body condition' do
        let(:bruce_person) { create(:person) }
        let(:bruce_alias) { create(:alias, name: 'Bruce Momjian', email: 'bruce@postgresql.org', person: bruce_person) }
        let(:tom_person) { create(:person) }
        let(:tom_alias) { create(:alias, name: 'Tom Lane', email: 'tom@postgresql.org', person: tom_person) }

        let!(:topic_bruce_patch) { create(:topic, title: 'Bruce Patch Topic') }
        let!(:topic_tom_patch) { create(:topic, title: 'Tom Patch Topic') }

        before do
          create(:message, topic: topic_bruce_patch, sender: bruce_alias, sender_person_id: bruce_person.id, body: 'Here is my patch for the issue')
          create(:message, topic: topic_tom_patch, sender: tom_alias, sender_person_id: tom_person.id, body: 'Here is my patch for the issue')
          topic_bruce_patch.update_denormalized_counts!
          topic_tom_patch.update_denormalized_counts!

          TopicParticipant.find_or_create_by!(topic: topic_bruce_patch, person: bruce_person) do |tp|
            tp.message_count = 1
            tp.first_message_at = 1.day.ago
            tp.last_message_at = 1.day.ago
          end
          TopicParticipant.find_or_create_by!(topic: topic_tom_patch, person: tom_person) do |tp|
            tp.message_count = 1
            tp.first_message_at = 1.day.ago
            tp.last_message_at = 1.day.ago
          end
        end

        it 'filters by body content for specific author' do
          result = build_query('from:bruce[body:patch]')
          expect(result.relation).to include(topic_bruce_patch)
          expect(result.relation).not_to include(topic_tom_patch)
        end
      end

      describe 'has:attachment with conditions' do
        let(:bruce_person) { create(:person) }
        let(:bruce_alias) { create(:alias, name: 'Bruce Momjian', email: 'bruce@postgresql.org', person: bruce_person) }
        let(:tom_person) { create(:person) }
        let(:tom_alias) { create(:alias, name: 'Tom Lane', email: 'tom@postgresql.org', person: tom_person) }

        let!(:topic_bruce_attachments) { create(:topic, title: 'Bruce Attachments') }
        let!(:topic_tom_attachments) { create(:topic, title: 'Tom Attachments') }
        let!(:topic_few_attachments) { create(:topic, title: 'Few Attachments') }

        before do
          # Bruce posts 3 attachments
          msg1 = create(:message, topic: topic_bruce_attachments, sender: bruce_alias, sender_person_id: bruce_person.id)
          create(:attachment, message: msg1, file_name: 'fix1.patch')
          create(:attachment, message: msg1, file_name: 'fix2.patch')
          msg2 = create(:message, topic: topic_bruce_attachments, sender: bruce_alias, sender_person_id: bruce_person.id)
          create(:attachment, message: msg2, file_name: 'fix3.patch')

          # Tom posts attachments
          msg3 = create(:message, topic: topic_tom_attachments, sender: tom_alias, sender_person_id: tom_person.id)
          create(:attachment, message: msg3, file_name: 'document.pdf')

          # Topic with 1 attachment
          msg4 = create(:message, topic: topic_few_attachments, sender: bruce_alias, sender_person_id: bruce_person.id)
          create(:attachment, message: msg4, file_name: 'readme.txt')
        end

        it 'filters by attachment author' do
          result = build_query('has:attachment[from:bruce]')
          expect(result.relation).to include(topic_bruce_attachments)
          expect(result.relation).to include(topic_few_attachments)
          expect(result.relation).not_to include(topic_tom_attachments)
        end

        it 'filters by attachment count' do
          result = build_query('has:attachment[count:>=3]')
          expect(result.relation).to include(topic_bruce_attachments)
          expect(result.relation).not_to include(topic_tom_attachments)
          expect(result.relation).not_to include(topic_few_attachments)
        end

        it 'combines from and count conditions' do
          result = build_query('has:attachment[from:bruce,count:>=3]')
          expect(result.relation).to include(topic_bruce_attachments)
          expect(result.relation).not_to include(topic_few_attachments)
        end

        it 'filters by attachment name' do
          result = build_query('has:attachment[name:patch]')
          expect(result.relation).to include(topic_bruce_attachments)
          expect(result.relation).not_to include(topic_tom_attachments)
          expect(result.relation).not_to include(topic_few_attachments)
        end
      end

      describe 'has:patch with conditions' do
        let(:bruce_person) { create(:person) }
        let(:bruce_alias) { create(:alias, name: 'Bruce Momjian', email: 'bruce@postgresql.org', person: bruce_person) }
        let(:tom_person) { create(:person) }
        let(:tom_alias) { create(:alias, name: 'Tom Lane', email: 'tom@postgresql.org', person: tom_person) }

        let!(:topic_bruce_patches) { create(:topic, title: 'Bruce Patches') }
        let!(:topic_tom_patches) { create(:topic, title: 'Tom Patches') }

        before do
          msg1 = create(:message, topic: topic_bruce_patches, sender: bruce_alias, sender_person_id: bruce_person.id)
          create(:attachment, message: msg1, file_name: 'fix1.patch')
          create(:attachment, message: msg1, file_name: 'fix2.diff')

          msg2 = create(:message, topic: topic_tom_patches, sender: tom_alias, sender_person_id: tom_person.id)
          create(:attachment, message: msg2, file_name: 'fix.patch')
        end

        it 'filters patches by author' do
          result = build_query('has:patch[from:bruce]')
          expect(result.relation).to include(topic_bruce_patches)
          expect(result.relation).not_to include(topic_tom_patches)
        end

        it 'filters patches by count' do
          result = build_query('has:patch[count:>=2]')
          expect(result.relation).to include(topic_bruce_patches)
          expect(result.relation).not_to include(topic_tom_patches)
        end
      end

      describe 'tag: with conditions' do
        let!(:topic_tagged_by_me) { create(:topic) }
        let!(:topic_tagged_by_other) { create(:topic) }
        let!(:topic_old_tag) { create(:topic) }
        let(:other_user) { create(:user, person: create(:person)) }

        before do
          note1 = create(:note, topic: topic_tagged_by_me, author: user, created_at: 1.day.ago)
          create(:note_tag, note: note1, tag: 'review')

          # Note from other_user, shared with current user via mention
          note2 = create(:note, topic: topic_tagged_by_other, author: other_user, created_at: 1.day.ago)
          create(:note_tag, note: note2, tag: 'review')
          create(:note_mention, note: note2, mentionable: user)

          note3 = create(:note, topic: topic_old_tag, author: user, created_at: 2.months.ago)
          create(:note_tag, note: note3, tag: 'review')
        end

        it 'filters tags by author using from: condition' do
          result = build_query('tag:review[from:me]')
          expect(result.relation).to include(topic_tagged_by_me)
          expect(result.relation).to include(topic_old_tag)
          expect(result.relation).not_to include(topic_tagged_by_other)
        end

        it 'filters tags by added_after' do
          result = build_query('tag:review[added_after:1w]')
          expect(result.relation).to include(topic_tagged_by_me)
          expect(result.relation).to include(topic_tagged_by_other)
          expect(result.relation).not_to include(topic_old_tag)
        end

        it 'filters tags by added_before' do
          result = build_query('tag:review[added_before:1w]')
          expect(result.relation).to include(topic_old_tag)
          expect(result.relation).not_to include(topic_tagged_by_me)
        end

        it 'combines from and date conditions' do
          result = build_query('tag:review[from:me, added_after:1w]')
          expect(result.relation).to include(topic_tagged_by_me)
          expect(result.relation).not_to include(topic_old_tag)
          expect(result.relation).not_to include(topic_tagged_by_other)
        end

        it 'filters any tag with from condition (empty tag name)' do
          result = build_query('tag:[from:me]')
          expect(result.relation).to include(topic_tagged_by_me)
          expect(result.relation).to include(topic_old_tag)
          expect(result.relation).not_to include(topic_tagged_by_other)
        end
      end

      describe 'team aggregation' do
        let(:team) { create(:team, name: 'core', visibility: :visible) }
        let(:bruce_person) { create(:person) }
        let(:bruce_user) { create(:user, person: bruce_person) }
        let(:tom_person) { create(:person) }
        let(:tom_user) { create(:user, person: tom_person) }
        let(:bruce_alias) { create(:alias, name: 'Bruce', person: bruce_person) }
        let(:tom_alias) { create(:alias, name: 'Tom', person: tom_person) }

        let!(:topic_team_active) { create(:topic, title: 'Team Active') }
        let!(:topic_team_inactive) { create(:topic, title: 'Team Inactive') }

        before do
          create(:team_member, team: team, user: bruce_user)
          create(:team_member, team: team, user: tom_user)

          # Team members active in first topic
          create(:message, topic: topic_team_active, sender: bruce_alias, sender_person_id: bruce_person.id)
          create(:message, topic: topic_team_active, sender: tom_alias, sender_person_id: tom_person.id)

          # Create/update topic_participants records
          tp1 = TopicParticipant.find_or_create_by!(topic: topic_team_active, person: bruce_person) do |tp|
            tp.first_message_at = 1.week.ago
            tp.last_message_at = 1.day.ago
          end
          tp1.update!(message_count: 5, first_message_at: 1.week.ago, last_message_at: 1.day.ago)

          tp2 = TopicParticipant.find_or_create_by!(topic: topic_team_active, person: tom_person) do |tp|
            tp.first_message_at = 1.week.ago
            tp.last_message_at = 2.days.ago
          end
          tp2.update!(message_count: 3, first_message_at: 1.week.ago, last_message_at: 2.days.ago)

          # Team members inactive in second topic - need to create messages first for the records to exist
          create(:message, topic: topic_team_inactive, sender: bruce_alias, sender_person_id: bruce_person.id)
          create(:message, topic: topic_team_inactive, sender: tom_alias, sender_person_id: tom_person.id)

          tp3 = TopicParticipant.find_or_create_by!(topic: topic_team_inactive, person: bruce_person) do |tp|
            tp.first_message_at = 3.months.ago
            tp.last_message_at = 2.months.ago
          end
          tp3.update!(message_count: 2, first_message_at: 3.months.ago, last_message_at: 2.months.ago)

          tp4 = TopicParticipant.find_or_create_by!(topic: topic_team_inactive, person: tom_person) do |tp|
            tp.first_message_at = 3.months.ago
            tp.last_message_at = 2.months.ago
          end
          tp4.update!(message_count: 1, first_message_at: 3.months.ago, last_message_at: 2.months.ago)

          topic_team_active.update_denormalized_counts!
          topic_team_inactive.update_denormalized_counts!
        end

        it 'aggregates message count across team members' do
          # Combined: 5+3=8 in active, 2+1=3 in inactive
          result = build_query('from:core[messages:>=5]')
          expect(result.relation).to include(topic_team_active)
          expect(result.relation).not_to include(topic_team_inactive)
        end

        it 'filters by activity date for all team members' do
          result = build_query('from:core[last_before:1m]')
          expect(result.relation).to include(topic_team_inactive)
          expect(result.relation).not_to include(topic_team_active)
        end
      end
    end

    describe 'FTS sanitization' do
      let!(:topic_vacuum) { create(:topic, title: 'Vacuum Performance Improvements') }
      let!(:topic_other) { create(:topic, title: 'Unrelated Topic') }

      before do
        create(:message, topic: topic_vacuum, body: 'Discussing vacuum improvements')
        create(:message, topic: topic_other, body: 'Something else entirely')
        topic_vacuum.update_denormalized_counts!
        topic_other.update_denormalized_counts!
      end

      it 'handles quoted phrases with special characters without errors' do
        # phraseto_tsquery handles special characters gracefully
        result = build_query('"vacuum & performance"')
        expect(result.warnings).to be_empty
      end

      it 'handles multiple spaces between search terms' do
        result = build_query('vacuum    performance')
        expect(result.relation).to include(topic_vacuum)
        expect(result.relation).not_to include(topic_other)
      end

      it 'searches title with FTS stemming' do
        # "improvements" should match via stemming (improve -> improv)
        result = build_query('title:improve')
        expect(result.relation).to include(topic_vacuum)
        expect(result.relation).not_to include(topic_other)
      end
    end
  end
end
