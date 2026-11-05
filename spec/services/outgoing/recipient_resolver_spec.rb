require 'rails_helper'

RSpec.describe Outgoing::RecipientResolver do
  let(:list)   { create(:mailing_list, post_address: "real@list.example") }
  let(:topic)  { create(:topic, mailing_lists: [ list ]) }
  let(:author) { create(:alias, name: "Bob", email: "bob@x") }
  let(:parent) { create(:message, topic: topic, sender: author) }
  let(:sender) { create(:alias, name: "Alice", email: "alice@x") }
  let(:draft)  {
    create(:outgoing_draft, topic: topic, reply_to_message: parent, sender_alias: sender)
  }

  def mention(email, name = "Noname")
    create(:mention, message: parent, alias: create(:alias, email: email, name: name))
  end

  context 'in production' do
    before { allow(Rails.env).to receive(:production?).and_return(true) }

    it 'puts the parent author in To and the list in Cc' do
      result = described_class.for(draft)
      expect(result.to).to eq([ 'Bob <bob@x>' ])
      expect(result.cc).to eq([ 'real@list.example' ])
    end

    it 'adds parent participants to Cc after the list' do
      mention('carol@x', 'Carol')
      result = described_class.for(draft)
      expect(result.cc).to eq([ 'real@list.example', 'Carol <carol@x>' ])
    end

    it 'uses the plain email when the participant name is Noname' do
      mention('dave@x')
      expect(described_class.for(draft).cc).to include('dave@x')
    end

    it 'falls back to the raw email when the address does not parse with a display name' do
      mention('bob at example dot com', 'Weird')
      expect(described_class.for(draft).cc).to include('bob at example dot com')
    end

    it 'excludes the sending alias from recipients' do
      create(:mention, message: parent, alias: sender)
      result = described_class.for(draft)
      expect(result.all.join).not_to include('alice@x')
    end

    it 'dedups addresses case-insensitively' do
      mention('BOB@X', 'Bobby')
      mention('carol@x', 'Carol')
      mention('CAROL@x', 'Caroline')
      result = described_class.for(draft)
      expect(result.to).to eq([ 'Bob <bob@x>' ])
      expect(result.cc).to eq([ 'real@list.example', 'Carol <carol@x>' ])
    end

    it 'drops fabricated unknown.user addresses' do
      mention('ghost@unknown.user', 'Ghost')
      expect(described_class.for(draft).all.join).not_to include('unknown.user')
    end

    it 'moves the list into To when replying to your own message' do
      parent.update!(sender: sender)
      mention('carol@x', 'Carol')
      result = described_class.for(draft)
      expect(result.to).to eq([ 'real@list.example' ])
      expect(result.cc).to eq([ 'Carol <carol@x>' ])
    end

    it 'moves the list into To when the parent sender address is fabricated' do
      parent.update!(sender: create(:alias, name: 'Ghost', email: 'ghost@unknown.user'))
      result = described_class.for(draft)
      expect(result.to).to eq([ 'real@list.example' ])
    end

    it 'raises MissingPostAddressError when post_address is blank' do
      list.update!(post_address: nil)
      expect { described_class.for(draft) }
        .to raise_error(Outgoing::RecipientResolver::MissingPostAddressError)
    end

    it 'raises MissingPostAddressError when topic has no mailing list' do
      topic.mailing_lists.clear
      expect { described_class.for(draft) }
        .to raise_error(Outgoing::RecipientResolver::MissingPostAddressError)
    end
  end

  context 'in development' do
    it 'returns only the override in To with empty Cc' do
      with_env('HACKORUM_DEV_REPLY_TO' => 'test@example.com') do
        result = described_class.for(draft)
        expect(result.to).to eq([ 'test@example.com' ])
        expect(result.cc).to eq([])
      end
    end

    it 'raises MissingDevOverrideError when override blank' do
      with_env('HACKORUM_DEV_REPLY_TO' => nil) do
        expect { described_class.for(draft) }
          .to raise_error(Outgoing::RecipientResolver::MissingDevOverrideError)
      end
    end

    it 'raises MissingDevOverrideError when override is empty string' do
      with_env('HACKORUM_DEV_REPLY_TO' => '') do
        expect { described_class.for(draft) }
          .to raise_error(Outgoing::RecipientResolver::MissingDevOverrideError)
      end
    end

    it 'raises RealListAddressInDevError when override matches a real list (case-insensitive)' do
      with_env('HACKORUM_DEV_REPLY_TO' => 'REAL@list.example') do
        expect { described_class.for(draft) }
          .to raise_error(Outgoing::RecipientResolver::RealListAddressInDevError)
      end
    end

    it 'returns the override even when the list has no post_address' do
      list.update!(post_address: nil)
      with_env('HACKORUM_DEV_REPLY_TO' => 'test@example.com') do
        expect(described_class.for(draft).to).to eq([ 'test@example.com' ])
      end
    end
  end

  context 'in staging (production env)' do
    before { allow(Rails.env).to receive(:production?).and_return(true) }

    it 'uses the dev override instead of the real list' do
      with_env('HACKORUM_ENV' => 'staging', 'HACKORUM_DEV_REPLY_TO' => 'test@example.com') do
        result = described_class.for(draft)
        expect(result.to).to eq([ 'test@example.com' ])
        expect(result.cc).to eq([])
      end
    end

    it 'fails closed when the override is missing' do
      with_env('HACKORUM_ENV' => 'staging', 'HACKORUM_DEV_REPLY_TO' => nil) do
        expect { described_class.for(draft) }
          .to raise_error(Outgoing::RecipientResolver::MissingDevOverrideError)
      end
    end
  end
end
