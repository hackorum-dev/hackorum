require 'rails_helper'

RSpec.describe 'People profile', type: :request do
  it 'renders a person profile page' do
    person = create(:person)
    alias_record = create(:alias, person: person, name: 'Profile Person', email: 'profile@example.com')
    person.update!(default_alias_id: alias_record.id)

    get person_path(alias_record.email)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Profile Person')
    expect(response.body).to include('profile@example.com')
  end

  describe 'window counter boxes' do
    let(:person) { create(:person) }
    let!(:person_alias) do
      al = create(:alias, person: person, name: 'Box Person', email: 'boxes@example.com')
      person.update!(default_alias_id: al.id)
      al
    end
    let(:other_alias) { create(:alias, person: create(:person), email: 'other@example.com') }

    before do
      own = create(:topic, creator_alias: person_alias, created_at: 3.days.ago)
      create(:message, topic: own, sender: person_alias, created_at: 3.days.ago, updated_at: 3.days.ago)
      create(:message, topic: own, sender: person_alias, created_at: 2.days.ago, updated_at: 2.days.ago)

      foreign = create(:topic, creator_alias: other_alias, created_at: 5.days.ago)
      create(:message, topic: foreign, sender: other_alias, created_at: 5.days.ago, updated_at: 5.days.ago)
      create(:message, topic: foreign, sender: person_alias, created_at: 1.day.ago, updated_at: 1.day.ago)
    end

    def summary_block(body)
      body[/<div class="activity-summary-groups">.*?<table/m]
    end

    def box_value(body, label)
      match = body.match(/<span class="summary-box-value">(\d+)<\/span><span class="summary-box-label">#{Regexp.escape(label)}<\/span>/)
      match && match[1].to_i
    end

    def box_classes(body, label)
      match = body.match(/<(?:div|a)[^>]*class="([^"]*)"[^>]*><span class="summary-box-value">\d+<\/span><span class="summary-box-label">#{Regexp.escape(label)}<\/span>/)
      match && match[1]
    end

    def threads_total(body)
      match = body.match(/<b>(\d+)<\/b> messages?<\/span>/)
      match && match[1].to_i
    end

    it 'groups the counters and totals them' do
      get person_path(person_alias.email)

      expect(response.body).to include('Replied to others')
      expect(response.body).to include('in 1 thread')
      expect(response.body).to include('summary-group')
    end

    it 'reports identical numbers regardless of the active filters' do
      get person_path(person_alias.email)
      unfiltered = summary_block(response.body)
      expect(unfiltered).to be_present

      get person_path(person_alias.email), params: { filters: [ 'started_thread' ] }

      expect(summary_block(response.body)).to eq(unfiltered)
    end

    it 'still filters the message table' do
      get person_path(person_alias.email), params: { filters: [ 'started_thread' ] }

      # scope to the table body: the filter checkbox label also says
      # "Replied (other)", so scanning the whole page would always find one
      table = response.body[/<table class="activity-table">.*/m]
      expect(table.scan('Replied (other)').size).to eq(0)
    end

    it 'keeps the summary visible when the filters match nothing' do
      # none of the fixture messages carry a patch, so this filter empties the table
      get person_path(person_alias.email), params: { filters: [ 'sent_first_patch' ] }

      expect(response.body).to include('activity-summary-groups')
      expect(threads_total(response.body)).to eq(3)
      expect(response.body).to include('No recent activity.')
    end

    it 'renders the total consistent with the started/replied breakdown' do
      get person_path(person_alias.email)

      total = threads_total(response.body)
      started = box_value(response.body, 'Started')
      replied_own = box_value(response.body, 'Replied in own')
      replied_other = box_value(response.body, 'Replied to others')

      expect(total).to eq(3)
      expect(started + replied_own + replied_other).to eq(total)
    end

    it 'pluralizes the total for a single message' do
      solo_person = create(:person)
      solo_alias = create(:alias, person: solo_person, name: 'Solo Person', email: 'solo@example.com')
      solo_person.update!(default_alias_id: solo_alias.id)
      topic = create(:topic, creator_alias: solo_alias, created_at: 1.day.ago)
      create(:message, topic: topic, sender: solo_alias, created_at: 1.day.ago, updated_at: 1.day.ago)

      get person_path(solo_alias.email)

      # a hardcoded plural would render "<b>1</b> messages" - assert the real text
      expect(response.body).to include('<b>1</b> message<')
      expect(response.body).not_to include('<b>1</b> messages')
    end

    context 'with a first patch and a follow-up' do
      let(:patch_person) { create(:person) }
      let!(:patch_alias) do
        al = create(:alias, person: patch_person, name: 'Patch Person', email: 'patchy@example.com')
        patch_person.update!(default_alias_id: al.id)
        al
      end

      before do
        topic = create(:topic, creator_alias: patch_alias, created_at: 2.days.ago)
        create(:message, topic: topic, sender: patch_alias, created_at: 2.days.ago, updated_at: 2.days.ago, is_patch_submission: true)
        create(:message, topic: topic, sender: patch_alias, created_at: 1.day.ago, updated_at: 1.day.ago, is_patch_submission: true)
      end

      it 'renders the patch total header with correct spacing' do
        get person_path(patch_alias.email)

        # a missing space here would render "of which2" - assert the real text
        expect(response.body).to include('of which <b>2</b> carried a patch')
      end

      it 'splits the first patch and the follow-up into their own boxes' do
        get person_path(patch_alias.email)

        expect(box_value(response.body, 'New patch')).to eq(1)
        expect(box_value(response.body, 'Follow-up')).to eq(1)
      end

      it 'marks the zero box as zero and leaves non-zero boxes alone' do
        get person_path(patch_alias.email)

        # no reply to a foreign thread happened, so that box is zero;
        # the started/patch boxes got a message each, so they are not
        expect(box_classes(response.body, 'Replied to others')).to include('zero')
        expect(box_classes(response.body, 'Started')).not_to include('zero')
      end
    end

    context 'replying twice in the same foreign thread' do
      let(:topics_person) { create(:person) }
      let!(:topics_alias) do
        al = create(:alias, person: topics_person, name: 'Topics Person', email: 'topics@example.com')
        topics_person.update!(default_alias_id: al.id)
        al
      end

      before do
        foreign = create(:topic, creator_alias: other_alias, created_at: 6.days.ago)
        create(:message, topic: foreign, sender: other_alias, created_at: 6.days.ago, updated_at: 6.days.ago)
        create(:message, topic: foreign, sender: topics_alias, created_at: 2.days.ago, updated_at: 2.days.ago)
        create(:message, topic: foreign, sender: topics_alias, created_at: 1.day.ago, updated_at: 1.day.ago)
      end

      it 'counts messages in the box but distinct topics in the sub-line' do
        get person_path(topics_alias.email)

        expect(box_value(response.body, 'Replied to others')).to eq(2)
        expect(response.body).to include('in 1 thread')
      end
    end

    context 'contribution calendar filtering' do
      let(:cal_person) { create(:person) }
      let!(:cal_alias) do
        al = create(:alias, person: cal_person, name: 'Calendar Person', email: 'calendar@example.com')
        cal_person.update!(default_alias_id: al.id)
        al
      end
      let(:cal_date) { Date.current - 10 }

      before do
        own = create(:topic, creator_alias: cal_alias, created_at: cal_date)
        create(:message, topic: own, sender: cal_alias, created_at: cal_date, updated_at: cal_date)

        foreign = create(:topic, creator_alias: other_alias, created_at: cal_date - 20)
        create(:message, topic: foreign, sender: other_alias, created_at: cal_date - 20, updated_at: cal_date - 20)
        create(:message, topic: foreign, sender: cal_alias, created_at: cal_date, updated_at: cal_date)
      end

      def day_tooltip(body, date)
        match = body.match(/title="#{Regexp.escape(date.iso8601)}: ([^"]+)"/)
        match && match[1]
      end

      it 'produces a different day count when filtered' do
        get person_path(cal_alias.email)
        unfiltered_tooltip = day_tooltip(response.body, cal_date)

        get person_path(cal_alias.email), params: { filters: [ 'started_thread' ] }
        filtered_tooltip = day_tooltip(response.body, cal_date)

        expect(unfiltered_tooltip).to eq('2 messages')
        expect(filtered_tooltip).to eq('1 message')
        expect(filtered_tooltip).not_to eq(unfiltered_tooltip)
      end
    end
  end

  describe 'all-time stat strip' do
    let(:person) { create(:person) }
    let!(:person_alias) do
      al = create(:alias, person: person, name: 'Strip Person', email: 'strip@example.com')
      person.update!(default_alias_id: al.id)
      al
    end

    before do
      topic = create(:topic, creator_alias: person_alias, title: 'Strip thread',
                     created_at: Time.utc(2020, 1, 1))
      create(:message, topic: topic, sender: person_alias, is_patch_submission: true,
             created_at: Time.utc(2020, 1, 1), updated_at: Time.utc(2020, 1, 1))
      create(:message, topic: topic, sender: person_alias,
             created_at: Time.utc(2024, 1, 1), updated_at: Time.utc(2024, 1, 1))

      commit = create(:commit)
      create(:commit_topic, commit: commit, topic: topic)
      CommitPerson.create!(commit: commit, role: 'author', person_id: person.id)
      CommitPerson.create!(commit: commit, role: 'committer', person_id: person.id)
    end

    it 'renders the tiles, the credits hero and the notable threads' do
      get person_path(person_alias.email)

      expect(response.body).to include('Messages sent')
      expect(response.body).to include('Threads started')
      expect(response.body).to include('Commit credits')
      expect(response.body).to include('credits-hero-value')
      expect(response.body).to include('Longest running')
      expect(response.body).to include('Strip thread')
    end

    it 'shows the distinct commit total, not the sum of the roles' do
      get person_path(person_alias.email)

      hero = response.body[/credits-hero-value">([^<]+)</, 1]
      expect(hero).to eq('1')
    end

    context 'with an llm-sourced credit' do
      before do
        CommitPerson.create!(commit: create(:commit), role: 'author', person_id: person.id, source: 'llm', confidence: 0.9)
      end

      it 'leaves it out of the hero total without the feature' do
        get person_path(person_alias.email)

        expect(response.body[/credits-hero-value">([^<]+)</, 1]).to eq('1')
      end

      it 'counts it with the patchset_lineage feature' do
        user = create(:user)
        create(:user_feature, user: user, feature: 'patchset_lineage')
        sign_in_as(user)

        get person_path(person_alias.email)

        expect(response.body[/credits-hero-value">([^<]+)</, 1]).to eq('2')
      end
    end

    it 'no longer renders the old activity-span line' do
      get person_path(person_alias.email)

      expect(response.body).not_to include('activity-span')
    end

    it 'omits the strip from the turbo-frame activity response' do
      get person_contributions_path(person_alias.email, year: 2024)

      expect(response.body).not_to include('credits-hero-value')
      expect(response.body).to include('person-activity')
    end

    it 'links tiles to search on the person profile' do
      get person_path(person_alias.email)

      expect(response.body).to match(/<a[^>]+class="stat-tile"/)
    end

    it 'labels the landed ratio with the commit-link era and both credited roles' do
      get person_path(person_alias.email)

      expect(response.body).to include(
        "reached a commit crediting them as author or committer"
      )
      expect(response.body).to include("since #{ProfileStats::COMMIT_LINK_ERA_START.year}")
      expect(response.body).not_to include("committed with them credited as author")
    end

    it 'titles the patches tile so it cannot be read as threads started' do
      get person_path(person_alias.email)

      expect(response.body).to include(
        %(title="Threads they sent a patch to, including threads started by other people")
      )
    end
  end

  describe 'landed patch rate era scoping' do
    let(:person) { create(:person) }
    let!(:person_alias) do
      al = create(:alias, person: person, name: 'Era Person', email: 'era@example.com')
      person.update!(default_alias_id: al.id)
      al
    end

    it 'excludes patch threads that predate the commit-link era from the ratio' do
      old_topic = create(:topic, creator_alias: person_alias, created_at: Date.new(2016, 6, 1))
      create(:message, topic: old_topic, sender: person_alias, is_patch_submission: true,
             created_at: Date.new(2016, 6, 1), updated_at: Date.new(2016, 6, 1))
      old_commit = create(:commit)
      create(:commit_topic, commit: old_commit, topic: old_topic)
      CommitPerson.create!(commit: old_commit, role: 'author', person_id: person.id)

      new_topic = create(:topic, creator_alias: person_alias, created_at: Date.new(2018, 1, 1))
      create(:message, topic: new_topic, sender: person_alias, is_patch_submission: true,
             created_at: Date.new(2018, 1, 1), updated_at: Date.new(2018, 1, 1))
      new_commit = create(:commit)
      create(:commit_topic, commit: new_commit, topic: new_topic)
      CommitPerson.create!(commit: new_commit, role: 'author', person_id: person.id)

      get person_path(person_alias.email)

      # all-time tile stays all-time: 2 patches across 2 threads
      expect(response.body).to include('across 2 threads')
      # the landed ratio only counts the post-2017 thread on both sides
      expect(response.body).to include('1 / 1')
      expect(response.body).to include('100% of patch threads since 2017')
    end
  end

  describe 'no-reply wording' do
    let(:person) { create(:person) }
    let!(:person_alias) do
      al = create(:alias, person: person, name: 'Quiet Person', email: 'quiet@example.com')
      person.update!(default_alias_id: al.id)
      al
    end

    it 'uses neutral wording instead of "never got a reply"' do
      topic = create(:topic, creator_alias: person_alias, created_at: 1.day.ago)
      create(:message, topic: topic, sender: person_alias, created_at: 1.day.ago, updated_at: 1.day.ago)

      get person_path(person_alias.email)

      expect(response.body).to include('1 of 1 have no replies')
      expect(response.body).not_to include('never got a reply')
    end
  end

  describe 'stat strip volume formatting' do
    let(:person) { create(:person) }
    let!(:person_alias) do
      al = create(:alias, person: person, name: 'Volume Person', email: 'volume@example.com')
      person.update!(default_alias_id: al.id)
      al
    end

    before do
      topic = create(:topic, creator_alias: person_alias, created_at: Time.utc(2021, 1, 1))
      Message.insert_all(
        (1..1000).map do |n|
          {
            topic_id: topic.id,
            sender_id: person_alias.id,
            sender_person_id: person.id,
            subject: "Bulk message #{n}",
            message_id: "<bulk-#{n}-#{topic.id}@example.com>",
            body: "bulk body #{n}",
            created_at: Time.utc(2021, 1, 1),
            updated_at: Time.utc(2021, 1, 1)
          }
        end
      )
    end

    it 'renders the messages-sent count with a thousands separator' do
      get person_path(person_alias.email)

      expect(response.body).to include('1,000')
    end
  end

  describe 'notable thread links' do
    let(:person) { create(:person) }
    let!(:person_alias) do
      al = create(:alias, person: person, name: 'Notable Person', email: 'notable@example.com')
      person.update!(default_alias_id: al.id)
      al
    end
    let!(:other_alias) { create(:alias, person: create(:person), email: 'other-notable@example.com') }
    let!(:third_alias) { create(:alias, person: create(:person), email: 'third-notable@example.com') }

    let!(:longest_topic) do
      t = create(:topic, creator_alias: person_alias, title: 'Longest Runner', created_at: Time.utc(2018, 1, 1))
      create(:message, topic: t, sender: person_alias, created_at: Time.utc(2018, 1, 1), updated_at: Time.utc(2018, 1, 1))
      create(:message, topic: t, sender: person_alias, created_at: Time.utc(2023, 1, 1), updated_at: Time.utc(2023, 1, 1))
      t
    end

    let!(:crowded_topic) do
      t = create(:topic, creator_alias: person_alias, title: 'Crowded Thread', created_at: Time.utc(2020, 1, 1))
      create(:message, topic: t, sender: person_alias, created_at: Time.utc(2020, 1, 1), updated_at: Time.utc(2020, 1, 1))
      create(:message, topic: t, sender: other_alias, sender_person_id: other_alias.person.id,
             created_at: Time.utc(2020, 1, 2), updated_at: Time.utc(2020, 1, 2))
      create(:message, topic: t, sender: third_alias, sender_person_id: third_alias.person.id,
             created_at: Time.utc(2020, 1, 3), updated_at: Time.utc(2020, 1, 3))
      t
    end

    let!(:chatty_topic) do
      t = create(:topic, creator_alias: person_alias, title: 'Chatty Thread', created_at: Time.utc(2021, 1, 1))
      5.times do |i|
        ts = Time.utc(2021, 1, 1) + i.days
        create(:message, topic: t, sender: person_alias, created_at: ts, updated_at: ts)
      end
      t
    end

    it 'links each notable thread row to its own topic' do
      get person_path(person_alias.email)

      expect(response.body).to include(%(href="#{topic_path(longest_topic)}"))
      expect(response.body).to include(%(href="#{topic_path(crowded_topic)}"))
      expect(response.body).to include(%(href="#{topic_path(chatty_topic)}"))
    end

    it 'renders all three rows when three different threads win a slot each' do
      get person_path(person_alias.email)

      expect(response.body.scan('notable-row').size).to eq(4) # started + 3 distinct winners
      expect(response.body).to include('Longest running')
      expect(response.body).to include('Most participants')
      expect(response.body).to include('Most messages')
      expect(response.body.scan('Longest Runner').size).to eq(1)
      expect(response.body.scan('Crowded Thread').size).to eq(1)
      expect(response.body.scan('Chatty Thread').size).to eq(1)
    end
  end

  describe 'notable thread dedupe' do
    let(:person) { create(:person) }
    let!(:person_alias) do
      al = create(:alias, person: person, name: 'Sweep Person', email: 'sweep@example.com')
      person.update!(default_alias_id: al.id)
      al
    end
    let!(:sweep_alias) { create(:alias, person: create(:person), email: 'sweep-other@example.com') }

    let!(:sweep_topic) do
      t = create(:topic, creator_alias: person_alias, title: 'Sweeping Thread', created_at: Time.utc(2019, 1, 1))
      create(:message, topic: t, sender: person_alias, created_at: Time.utc(2019, 1, 1), updated_at: Time.utc(2019, 1, 1))
      create(:message, topic: t, sender: sweep_alias, sender_person_id: sweep_alias.person.id,
             created_at: Time.utc(2019, 1, 2), updated_at: Time.utc(2019, 1, 2))
      create(:message, topic: t, sender: person_alias, created_at: Time.utc(2024, 1, 1), updated_at: Time.utc(2024, 1, 1))
      t
    end

    it 'renders the single thread once, not three times' do
      get person_path(person_alias.email)

      expect(response.body.scan('Sweeping Thread').size).to eq(1)
      expect(response.body.scan('notable-row').size).to eq(2) # started + one winner row
    end
  end

  describe 'notable thread dedupe, longest tied with most-messages' do
    let(:person) { create(:person) }
    let!(:person_alias) do
      al = create(:alias, person: person, name: 'Overlap Person', email: 'overlap@example.com')
      person.update!(default_alias_id: al.id)
      al
    end
    let!(:other_alias) { create(:alias, person: create(:person), email: 'overlap-other@example.com') }
    let!(:third_alias) { create(:alias, person: create(:person), email: 'overlap-third@example.com') }

    # long-running AND the most messages, but only one participant (the person
    # themselves) - this must win "Longest running" and "Most messages" but not
    # "Most participants"
    let!(:long_and_chatty) do
      t = create(:topic, creator_alias: person_alias, title: 'Long And Chatty', created_at: Time.utc(2016, 1, 1))
      6.times do |i|
        ts = Time.utc(2016, 1, 1) + i.years
        create(:message, topic: t, sender: person_alias, created_at: ts, updated_at: ts)
      end
      t
    end

    # short-running with three participants but few messages - wins
    # "Most participants" only
    let!(:crowded_only) do
      t = create(:topic, creator_alias: person_alias, title: 'Crowded Only', created_at: Time.utc(2024, 1, 1))
      create(:message, topic: t, sender: person_alias, created_at: Time.utc(2024, 1, 1), updated_at: Time.utc(2024, 1, 1))
      create(:message, topic: t, sender: other_alias, sender_person_id: other_alias.person.id,
             created_at: Time.utc(2024, 1, 2), updated_at: Time.utc(2024, 1, 2))
      create(:message, topic: t, sender: third_alias, sender_person_id: third_alias.person.id,
             created_at: Time.utc(2024, 1, 3), updated_at: Time.utc(2024, 1, 3))
      t
    end

    it 'renders the shared longest/most-messages winner once and the participants winner separately' do
      get person_path(person_alias.email)

      expect(response.body.scan('Long And Chatty').size).to eq(1)
      expect(response.body.scan('Crowded Only').size).to eq(1)
      expect(response.body.scan('notable-row').size).to eq(3) # started + longest(=most messages) + most participants
      expect(response.body).to include('Longest running')
      expect(response.body).to include('Most participants')
      expect(response.body).not_to include('Most messages')
    end
  end

  describe 'notable thread dedupe, most-participants tied with most-messages' do
    let(:person) { create(:person) }
    let!(:person_alias) do
      al = create(:alias, person: person, name: 'Overlap Two Person', email: 'overlap-two@example.com')
      person.update!(default_alias_id: al.id)
      al
    end
    let!(:other_alias) { create(:alias, person: create(:person), email: 'overlap-two-other@example.com') }
    let!(:third_alias) { create(:alias, person: create(:person), email: 'overlap-two-third@example.com') }

    # long-running, but only the person ever posts in it - wins "Longest
    # running" only
    let!(:long_only) do
      t = create(:topic, creator_alias: person_alias, title: 'Long Runner Only', created_at: Time.utc(2015, 1, 1))
      create(:message, topic: t, sender: person_alias, created_at: Time.utc(2015, 1, 1), updated_at: Time.utc(2015, 1, 1))
      create(:message, topic: t, sender: person_alias, created_at: Time.utc(2023, 1, 1), updated_at: Time.utc(2023, 1, 1))
      t
    end

    # short-running, but three participants who each post twice - wins both
    # "Most participants" and "Most messages"
    let!(:crowded_and_chatty) do
      t = create(:topic, creator_alias: person_alias, title: 'Crowded And Chatty', created_at: Time.utc(2024, 1, 1))
      [ person_alias, other_alias, third_alias ].each_with_index do |al, idx|
        person_id = al == person_alias ? person.id : al.person.id
        2.times do |i|
          ts = Time.utc(2024, 1, 1) + (idx * 2 + i).days
          create(:message, topic: t, sender: al, sender_person_id: person_id, created_at: ts, updated_at: ts)
        end
      end
      t
    end

    it 'renders the shared participants/messages winner once and the longest winner separately' do
      get person_path(person_alias.email)

      expect(response.body.scan('Long Runner Only').size).to eq(1)
      expect(response.body.scan('Crowded And Chatty').size).to eq(1)
      expect(response.body.scan('notable-row').size).to eq(3) # started + longest + participants(=most messages)
      expect(response.body).to include('Longest running')
      expect(response.body).to include('Most participants')
      expect(response.body).not_to include('Most messages')
    end
  end

  describe 'empty profile' do
    it 'renders the stat strip for a person with no activity at all' do
      person = create(:person)
      al = create(:alias, person: person, name: 'Empty Person', email: 'empty@example.com')
      person.update!(default_alias_id: al.id)

      get person_path(al.email)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Messages sent')
      expect(response.body).to include('Commit credits')
    end
  end

  describe 'window box links' do
    let(:person) { create(:person) }
    let!(:person_alias) do
      al = create(:alias, person: person, name: 'Link Person', email: 'links@example.com')
      person.update!(default_alias_id: al.id)
      al
    end

    before do
      topic = create(:topic, creator_alias: person_alias, created_at: 2.days.ago)
      create(:message, topic: topic, sender: person_alias, created_at: 2.days.ago, updated_at: 2.days.ago)
    end

    it 'links the started box to a date-bounded starter search' do
      get person_path(person_alias.email)

      expect(response.body).to include(CGI.escapeHTML(search_topics_path(
        q: "starter:\"links@example.com\" first_after:#{30.days.ago.beginning_of_day.to_date} first_before:#{Date.current + 1}"
      )))
    end

    it 'uses the month bounds on a monthly view' do
      get person_monthly_activity_path(person_alias.email, 2026, 3)

      expect(response.body).to include(CGI.escapeHTML(search_topics_path(
        q: "starter:\"links@example.com\" first_after:2026-03-01 first_before:2026-04-01"
      )))
    end

    it 'uses the single day as both bounds on a daily view' do
      get person_activity_path(person_alias.email, '2026-03-15')

      expect(response.body).to include(CGI.escapeHTML(search_topics_path(
        q: "starter:\"links@example.com\" first_after:2026-03-15 first_before:2026-03-16"
      )))
    end

    it 'uses the week bounds on a weekly view, and not the raw end date' do
      start_date = WeekCalculation.week_start_date(2026, 3)
      end_date = start_date + 6
      get person_weekly_activity_path(person_alias.email, 2026, 3)

      expect(response.body).to include(CGI.escapeHTML(search_topics_path(
        q: "starter:\"links@example.com\" first_after:#{start_date} first_before:#{end_date + 1}"
      )))
      # pins the off-by-one: the raw end date (no +1) must not be what first_before carries
      expect(response.body).not_to include(CGI.escapeHTML(search_topics_path(
        q: "starter:\"links@example.com\" first_after:#{start_date} first_before:#{end_date}"
      )))
    end

    it 'links only the Started box among the summary boxes' do
      get person_path(person_alias.email)

      region = response.body[/<div class="activity-summary-groups">.*?<table/m]
      expect(region).to be_present
      expect(region.scan('<a ').size).to eq(1)
    end
  end

  describe 'patches tile link' do
    let(:person) { create(:person) }
    let!(:person_alias) do
      al = create(:alias, person: person, name: 'Patch Person', email: 'bracket-patch@example.com')
      person.update!(default_alias_id: al.id)
      al
    end

    # is_patch_submission is only ever set via Message#recompute_patch_submission!,
    # which requires attachments.any?(&:patch_submission_candidate?) - so a patch
    # message always has a matching attachment. has:patch[from:] is therefore the
    # faithful link: it matches exactly what patches_sent counts.
    it 'renders the patches tile link as the bracket form, not two independently-ANDed selectors' do
      topic = create(:topic, creator_alias: person_alias, title: 'Attached Patch Thread')
      message = create(:message, topic: topic, sender: person_alias, is_patch_submission: true)
      create(:attachment, message: message)

      get person_path(person_alias.email)

      expect(response.body).to include(CGI.escapeHTML(search_topics_path(
        q: 'has:patch[from:"bracket-patch@example.com"]'
      )))
      expect(response.body).not_to include('from:"bracket-patch@example.com" has:patch')
    end

    it 'finds the patch through the linked search, with quoting still blocking a substring email' do
      collision_person = create(:person)
      collision_alias = create(:alias, person: collision_person, email: 'cal-bracket-patch@example.com')

      topic = create(:topic, creator_alias: person_alias, title: 'Attached Patch Thread')
      message = create(:message, topic: topic, sender: person_alias, is_patch_submission: true)
      create(:attachment, message: message)

      other_topic = create(:topic, creator_alias: collision_alias, title: 'Collision Patch Thread')
      other_message = create(:message, topic: other_topic, sender: collision_alias,
                              sender_person_id: collision_person.id, is_patch_submission: true)
      create(:attachment, message: other_message)

      get search_topics_path, params: { q: 'has:patch[from:"bracket-patch@example.com"]' }

      expect(response.body).to include('Attached Patch Thread')
      expect(response.body).not_to include('Collision Patch Thread')
    end
  end

  describe 'email quoting on the profile tiles' do
    let(:person) { create(:person) }
    let!(:person_alias) do
      al = create(:alias, person: person, name: 'Short Name', email: 'al@example.com')
      person.update!(default_alias_id: al.id)
      al
    end
    let!(:collision_person) { create(:person) }
    # deliberately a superstring containing al@example.com, so unquoted ILIKE
    # '%al@example.com%' would match this alias's email too
    let!(:collision_alias) { create(:alias, person: collision_person, email: 'cal@example.com') }

    it 'does not let the started-box search pull in an email that merely contains it' do
      own_topic = create(:topic, creator_alias: person_alias, title: 'Al Started This')
      create(:message, topic: own_topic, sender: person_alias, created_at: own_topic.created_at, updated_at: own_topic.created_at)

      other_topic = create(:topic, creator_alias: collision_alias, title: 'Cal Started This')
      create(:message, topic: other_topic, sender: collision_alias, sender_person_id: collision_person.id,
             created_at: other_topic.created_at, updated_at: other_topic.created_at)

      get person_path(person_alias.email)
      href_query = 'starter:"al@example.com" first_after:' \
                   "#{30.days.ago.beginning_of_day.to_date} first_before:#{Date.current + 1}"
      expect(response.body).to include(CGI.escapeHTML(search_topics_path(q: href_query)))

      get search_topics_path, params: { q: href_query }

      expect(response.body).to include('Al Started This')
      expect(response.body).not_to include('Cal Started This')
    end

    it 'does not let the joined-box search pull in an email that merely contains it' do
      own_topic = create(:topic, creator_alias: collision_alias, title: 'Cal Owns This')
      create(:message, topic: own_topic, sender: person_alias, sender_person_id: person.id)

      get search_topics_path, params: { q: 'from:"al@example.com"' }

      expect(response.body).to include('Cal Owns This')

      other_topic = create(:topic, creator_alias: collision_alias, title: 'Cal Alone Here')
      create(:message, topic: other_topic, sender: collision_alias, sender_person_id: collision_person.id)

      get search_topics_path, params: { q: 'from:"al@example.com"' }

      expect(response.body).not_to include('Cal Alone Here')
    end
  end

  describe '30-day window consistency' do
    let(:person) { create(:person) }
    let!(:person_alias) do
      al = create(:alias, person: person, name: 'Cutoff Person', email: 'cutoff@example.com')
      person.update!(default_alias_id: al.id)
      al
    end

    it 'keeps the started box and its search link on the same 30-day cutoff across a 31-day month' do
      travel_to Time.zone.local(2026, 7, 31, 12, 0, 0) do
        in_window = create(:topic, creator_alias: person_alias, title: 'Inside The Window',
                           created_at: Time.zone.local(2026, 7, 1, 0, 0, 1))
        create(:message, topic: in_window, sender: person_alias,
               created_at: in_window.created_at, updated_at: in_window.created_at)

        out_of_window = create(:topic, creator_alias: person_alias, title: 'Outside The Window',
                               created_at: Time.zone.local(2026, 6, 30, 23, 59, 59))
        create(:message, topic: out_of_window, sender: person_alias,
               created_at: out_of_window.created_at, updated_at: out_of_window.created_at)

        get person_path(person_alias.email)

        started = response.body.match(
          /<span class="summary-box-value">(\d+)<\/span><span class="summary-box-label">Started<\/span>/
        )[1].to_i
        expect(started).to eq(1) # only the in-window thread should land in the box

        range_start = 30.days.ago.beginning_of_day.to_date
        range_end = Date.current
        expected_query = "starter:\"#{person_alias.email}\" first_after:#{range_start} first_before:#{range_end + 1}"
        expect(response.body).to include(CGI.escapeHTML(search_topics_path(q: expected_query)))

        get search_topics_path, params: { q: expected_query }

        expect(response.body).to include('Inside The Window')
        expect(response.body).not_to include('Outside The Window')
      end
    end
  end

  describe 'stat strip position' do
    let(:person) { create(:person) }
    let!(:person_alias) do
      al = create(:alias, person: person, name: 'Position Person', email: 'position@example.com')
      person.update!(default_alias_id: al.id)
      al
    end

    it 'renders the stat strip before the activity turbo-frame, not inside it' do
      get person_path(person_alias.email)

      expect(response.body.index('profile-stats')).to be < response.body.index('person-activity')
    end
  end

  describe 'impact bar width' do
    let(:person) { create(:person) }
    let!(:person_alias) do
      al = create(:alias, person: person, name: 'Impact Person', email: 'impact@example.com')
      person.update!(default_alias_id: al.id)
      al
    end

    it 'sets the bar width to the actual landed rate, not a fixed 100%' do
      topics = Array.new(3) do
        t = create(:topic, creator_alias: person_alias, created_at: Date.new(2020, 1, 1))
        create(:message, topic: t, sender: person_alias, is_patch_submission: true,
               created_at: Date.new(2020, 1, 1), updated_at: Date.new(2020, 1, 1))
        t
      end
      topics.first(2).each do |t|
        commit = create(:commit)
        create(:commit_topic, commit: commit, topic: t)
        CommitPerson.create!(commit: commit, role: 'author', person_id: person.id)
      end

      get person_path(person_alias.email)

      expect(response.body).to include('2 / 3')
      expect(response.body).to include('style="width: 67%"')
      expect(response.body).not_to include('style="width: 100%"')
    end
  end

  describe 'large numbers formatting' do
    let(:person) { create(:person) }
    let!(:person_alias) do
      al = create(:alias, person: person, name: 'Bulk Number Person', email: 'bulk-numbers@example.com')
      person.update!(default_alias_id: al.id)
      al
    end

    before do
      ts = 3.days.ago

      topic_rows = (1..1000).map do |n|
        {
          title: "Bulk patch topic #{n}",
          creator_id: person_alias.id,
          creator_person_id: person.id,
          created_at: ts,
          updated_at: ts,
          message_count: 1,
          participant_count: 1,
          last_message_at: ts,
          last_sender_person_id: person.id
        }
      end
      Topic.insert_all(topic_rows)
      topic_ids = Topic.where(creator_person_id: person.id).order(:id).pluck(:id)

      message_rows = topic_ids.each_with_index.map do |topic_id, i|
        {
          topic_id: topic_id,
          sender_id: person_alias.id,
          sender_person_id: person.id,
          subject: "Bulk patch message #{i}",
          message_id: "<bulk-patch-#{i}@example.com>",
          body: "bulk patch body #{i}",
          is_patch_submission: true,
          created_at: ts,
          updated_at: ts
        }
      end
      Message.insert_all(message_rows)

      commit_rows = (1..1000).map do |n|
        {
          sha: Digest::SHA1.hexdigest("bulk-commit-#{n}"),
          subject: "Bulk commit #{n}",
          authored_at: ts,
          committed_at: ts,
          branches: [ "master" ],
          created_at: ts,
          updated_at: ts
        }
      end
      result = Commit.insert_all(commit_rows, returning: [ :id ])
      commit_ids = result.rows.flatten

      commit_topic_rows = commit_ids.zip(topic_ids).map do |commit_id, topic_id|
        { commit_id: commit_id, topic_id: topic_id }
      end
      CommitTopic.insert_all(commit_topic_rows)

      commit_person_rows = commit_ids.map do |commit_id|
        { commit_id: commit_id, role: 'author', person_id: person.id }
      end
      CommitPerson.insert_all(commit_person_rows)
    end

    it 'formats every profile stat above 999 with a thousands separator' do
      # the fixture message set doesn't overlap the filter, so the table
      # empties out while the (unfiltered) summary numbers stay full-size
      get person_path(person_alias.email), params: { filters: [ 'replied_own_thread' ] }

      expect(response.body).to include('<span class="credits-hero-value">1,000</span>')
      expect(response.body).to include(
        '<span class="credit-item-value">1,000</span><span class="credit-item-label">Author</span>'
      )
      expect(response.body).to include('1,000 / 1,000')
      expect(response.body).to include('1,000 of 1,000 have no replies')
      expect(response.body).to include('<b>1,000</b> messages')
    end
  end

  describe 'backport commit credits' do
    let(:person) { create(:person) }
    let!(:person_alias) do
      al = create(:alias, person: person, name: 'Backport Person', email: 'backport-tile@example.com')
      person.update!(default_alias_id: al.id)
      al
    end

    it 'keeps the master commit out of the hero total and shows the backport separately' do
      master_commit = create(:commit, branches: [ 'master' ])
      CommitPerson.create!(commit: master_commit, role: 'author', person_id: person.id)

      backport_commit = create(:commit, branches: [ 'REL_17_STABLE' ], cherry_picked_from_sha: master_commit.sha)
      CommitPerson.create!(commit: backport_commit, role: 'author', person_id: person.id)

      get person_path(person_alias.email)

      # one master commit, not two - the backport must not inflate the hero
      expect(response.body).to include('<span class="credits-hero-value">1</span>')
      expect(response.body).to include(
        '<span class="credit-item-value">1</span><span class="credit-item-label">Backports</span>'
      )
    end

    it 'does not show a backport reviewer credit in the backports tile' do
      master_commit = create(:commit, branches: [ 'master' ])
      backport_commit = create(:commit, branches: [ 'REL_17_STABLE' ], cherry_picked_from_sha: master_commit.sha)
      CommitPerson.create!(commit: backport_commit, role: 'reviewer', person_id: person.id)

      get person_path(person_alias.email)

      expect(response.body).to include(
        '<span class="credit-item-value">0</span><span class="credit-item-label">Backports</span>'
      )
    end
  end

  describe 'activity tabs' do
    let(:tab_person) { create(:person) }
    let!(:tab_alias) do
      al = create(:alias, person: tab_person, name: 'Tab Person', email: 'tabs@example.com')
      tab_person.update!(default_alias_id: al.id)
      al
    end

    it 'defaults to the email activity tab' do
      get person_path('tabs@example.com')

      expect(response.body).to include('Email activity')
      expect(response.body).to include('Commit activity')
      expect(response.body).to match(/profile-tab[^>]*is-active[^>]*>\s*Email activity/)
    end

    it 'defers the commit frame until its panel becomes visible' do
      get person_path('tabs@example.com')

      frame = Nokogiri::HTML(response.body).at_css('turbo-frame#person-commit-activity')
      expect(frame['loading']).to eq('lazy')
      expect(frame['src']).to eq(person_commits_path('tabs@example.com'))
      # an empty body is what proves none of the commit queries ran
      expect(frame.children.reject { |node| node.text.strip.empty? }).to be_empty
      expect(response.body).not_to include('commit-activity-table')
    end

    it 'carries the week start into the commit frame so both calendars agree' do
      get person_path('tabs@example.com', week_start: 'sun')

      frame = Nokogiri::HTML(response.body).at_css('turbo-frame#person-commit-activity')
      expect(frame['src']).to eq(person_commits_path('tabs@example.com', week_start: 'sun'))
    end

    it 'activates the commit tab eagerly with ?tab=commits' do
      get person_path('tabs@example.com', tab: 'commits')

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css('#profile-tab-commits')['aria-selected']).to eq('true')
      expect(doc.at_css('#profile-tab-messages')['aria-selected']).to eq('false')
      expect(doc.at_css('turbo-frame#person-commit-activity')['loading']).to be_nil
    end

    it 'still renders the message activity table' do
      get person_path('tabs@example.com')

      expect(response.body).to include('id="person-activity"')
      expect(response.body).to include('activity-filters')
    end
  end
end
