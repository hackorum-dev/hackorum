# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Search::ValueResolver, type: :service do
  let(:person) { create(:person) }
  let(:user) { create(:user, person: person) }
  let(:resolver) { described_class.new(user: user) }

  describe '#resolve_author' do
    context 'with me value' do
      it 'resolves to current user person_id' do
        result = resolver.resolve_author('me')
        expect(result.type).to eq(:persons)
        expect(result.person_ids).to eq([ person.id ])
        expect(result.warnings).to be_empty
      end

      it 'returns empty with warning when not signed in' do
        resolver_no_user = described_class.new(user: nil)
        result = resolver_no_user.resolve_author('me')
        expect(result.type).to eq(:empty)
        expect(result.warnings).to include(/signed in/i)
      end
    end

    context 'with contributor type' do
      let!(:contributor_person) { create(:person) }
      let!(:contributor_membership) { ContributorMembership.create!(person: contributor_person, contributor_type: 'committer') }

      it 'resolves contributor to all contributor person_ids' do
        result = resolver.resolve_author('contributor')
        expect(result.type).to eq(:persons)
        expect(result.person_ids).to include(contributor_person.id)
      end

      it 'resolves specific contributor type' do
        result = resolver.resolve_author('committer')
        expect(result.type).to eq(:persons)
        expect(result.person_ids).to include(contributor_person.id)
      end
    end

    context 'with team name' do
      let(:team) { create(:team, name: 'postgresql-core', visibility: :visible) }
      let(:team_member_person) { create(:person) }
      let(:team_member_user) { create(:user, person: team_member_person) }

      before do
        create(:team_member, team: team, user: team_member_user)
      end

      it 'resolves team name to team member person_ids' do
        result = resolver.resolve_author('postgresql-core')
        expect(result.type).to eq(:persons)
        expect(result.person_ids).to include(team_member_person.id)
      end

      it 'does not resolve inaccessible private team' do
        private_team = create(:team, name: 'secret-team', visibility: :private)
        create(:team_member, team: private_team, user: team_member_user)

        result = resolver.resolve_author('secret-team')
        # Since user is not a member, it should fall back to name/email search
        expect(result.type).to eq(:empty)
      end
    end

    context 'with email value' do
      let(:alias_record) { create(:alias, email: 'john@example.com', name: 'John Doe', person: create(:person)) }

      before { alias_record }

      it 'searches email only when value contains @' do
        result = resolver.resolve_author('john@example.com')
        expect(result.type).to eq(:persons)
        expect(result.person_ids).to include(alias_record.person_id)
      end

      it 'uses exact match when quoted' do
        result = resolver.resolve_author('john@example.com', quoted: true)
        expect(result.type).to eq(:persons)
      end
    end

    context 'with name value' do
      let(:alias_record) { create(:alias, email: 'different@example.com', name: 'John Doe', person: create(:person)) }

      before { alias_record }

      it 'searches both name and email when no @' do
        result = resolver.resolve_author('john')
        expect(result.type).to eq(:persons)
        expect(result.person_ids).to include(alias_record.person_id)
      end

      it 'uses exact match when quoted' do
        result = resolver.resolve_author('John Doe', quoted: true)
        expect(result.type).to eq(:persons)
        expect(result.person_ids).to include(alias_record.person_id)
      end
    end
  end

  describe '#resolve_state_subject' do
    context 'with me value' do
      it 'resolves to current user_id' do
        result = resolver.resolve_state_subject('me')
        expect(result.type).to eq(:users)
        expect(result.user_ids).to eq([ user.id ])
      end

      it 'returns empty with warning when not signed in' do
        resolver_no_user = described_class.new(user: nil)
        result = resolver_no_user.resolve_state_subject('me')
        expect(result.type).to eq(:empty)
        expect(result.warnings).to include(/signed in/i)
      end
    end

    context 'with team name' do
      let(:team) { create(:team, name: 'my-team', visibility: :visible) }
      let(:teammate) { create(:user, person: create(:person)) }

      before do
        create(:team_member, team: team, user: user)
        create(:team_member, team: team, user: teammate)
      end

      it 'resolves to team member user_ids when user is member' do
        result = resolver.resolve_state_subject('my-team')
        expect(result.type).to eq(:users)
        expect(result.user_ids).to include(user.id, teammate.id)
      end

      it 'returns empty when user is not a team member' do
        other_user = create(:user, person: create(:person))
        other_resolver = described_class.new(user: other_user)
        result = other_resolver.resolve_state_subject('my-team')
        expect(result.type).to eq(:empty)
      end
    end
  end

  describe '#resolve_tag' do
    context 'with plain tag name' do
      it 'resolves to tag_name with nil user_ids (all accessible)' do
        result = resolver.resolve_tag('review')
        expect(result.tag_name).to eq('review')
        expect(result.user_ids).to be_nil
        expect(result.warnings).to be_empty
      end

      it 'lowercases tag names' do
        result = resolver.resolve_tag('Review')
        expect(result.tag_name).to eq('review')
      end
    end

    context 'when not signed in' do
      let(:resolver_no_user) { described_class.new(user: nil) }

      it 'returns empty with warning' do
        result = resolver_no_user.resolve_tag('review')
        expect(result.tag_name).to be_nil
        expect(result.warnings).to include(/signed in/i)
      end
    end
  end

  describe '#contributor_type?' do
    it 'returns true for valid contributor types' do
      expect(resolver.contributor_type?('contributor')).to be true
      expect(resolver.contributor_type?('committer')).to be true
      expect(resolver.contributor_type?('core_team')).to be true
    end

    it 'returns false for non-contributor values' do
      expect(resolver.contributor_type?('john')).to be false
      expect(resolver.contributor_type?('me')).to be false
    end
  end

  describe '#email_value?' do
    it 'returns true when value contains @' do
      expect(resolver.email_value?('john@example.com')).to be true
      expect(resolver.email_value?('@example.com')).to be true
    end

    it 'returns false when value does not contain @' do
      expect(resolver.email_value?('john')).to be false
      expect(resolver.email_value?('John Doe')).to be false
    end
  end
end
