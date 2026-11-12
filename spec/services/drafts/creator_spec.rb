require "rails_helper"

RSpec.describe Drafts::Creator do
  let(:user) { create(:user) }
  let!(:identity) { create(:identity, user: user, email: "a@b", refresh_token: "r", send_authorized_at: 1.hour.ago) }
  let!(:sender) { create(:alias, user: user, email: "a@b", name: "Alice") }
  let(:topic) { create(:topic) }
  let(:parent) { create(:message, topic: topic, subject: "RE: Re: Hello", created_at: Time.utc(2026, 3, 2, 10)) }

  def call(**options)
    described_class.call(user: user, reply_to_message: parent, **options)
  end

  it "creates a draft with the defaults of the composer" do
    result = call

    expect(result).to be_created
    expect(result.draft).to have_attributes(
      user: user, topic: topic, reply_to_message: parent, identity: identity, sender_alias: sender,
      subject: "Re: Re: Hello", body: "", status: "idle", created_via_token_id: nil, last_edited_via_token_id: nil
    )
  end

  it "strips one aw: or fwd: prefix as well" do
    parent.update!(subject: "Fwd: news")
    expect(call.draft.subject).to eq("Re: news")
  end

  it "quotes the given text under an attribution line" do
    display = parent.sender_display_alias

    expect(call(quote: " one\ntwo \n").draft.body)
      .to eq("On Mon, 02 Mar 2026, #{display.name} <#{display.email}> wrote:\n> one\n> two\n\n")
  end

  it "takes a subject and a body, the quote goes in front of the body" do
    token = ApiToken.issue!(user: user, name: "laptop").first

    draft = call(subject: "Re: mine", body: "my answer", quote: "theirs", token: token).draft

    expect(draft.subject).to eq("Re: mine")
    expect(draft.body).to end_with("wrote:\n> theirs\n\nmy answer")
    expect(draft.created_via_token).to eq(token)
    expect(draft.last_edited_via_token).to be_nil
    expect(call(body: "only").draft).to eq(draft)
  end

  it "takes a body without a quote as it is" do
    expect(call(body: "just this").draft.body).to eq("just this")
  end

  it "gives the active draft of the parent back untouched" do
    first = call(subject: "Re: kept", body: "kept").draft
    stamp = first.reload.updated_at

    result = call(subject: "Re: other", body: "other", quote: "q", token: ApiToken.issue!(user: user, name: "t").first)

    expect(result).not_to be_created
    expect(result.draft).to eq(first)
    expect(first.reload).to have_attributes(subject: "Re: kept", body: "kept", created_via_token_id: nil, updated_at: stamp)
  end

  it "gives a sending draft back and makes a new one next to a sent one" do
    sending = call.draft
    sending.update!(status: "sending", sending_started_at: Time.current)
    expect(call.draft).to eq(sending)

    sending.update!(status: "sent", sent_at: Time.current)
    result = call
    expect(result).to be_created
    expect(result.draft).not_to eq(sending)
  end

  it "keeps the drafts of other users and other parents apart" do
    other = create(:outgoing_draft, reply_to_message: parent, topic: topic)
    elsewhere = create(:outgoing_draft, user: user, identity: identity, sender_alias: sender)

    result = call

    expect(result).to be_created
    expect([ other, elsewhere ]).not_to include(result.draft)
  end

  it "needs a send-authorized identity" do
    identity.update!(send_revoked_at: Time.current)

    expect { call }.to raise_error(described_class::NoSendIdentity)
    expect(OutgoingDraft.count).to eq(0)
  end

  it "needs an alias for the address of the identity" do
    sender.update!(email: "different@b")

    expect { call }.to raise_error(described_class::NoSenderAlias)
  end

  describe "when another request made the draft in between" do
    let!(:existing) { create(:outgoing_draft, user: user, topic: topic, reply_to_message: parent, identity: identity, sender_alias: sender) }

    def blind_first_lookup
      looked = 0
      allow_any_instance_of(described_class).to receive(:active_draft).and_wrap_original do |original|
        (looked += 1) == 1 ? nil : original.call
      end
    end

    def expect_existing_inside_a_transaction
      result = nil
      ActiveRecord::Base.transaction(requires_new: true) do
        result = call(body: "late")
        expect(OutgoingDraft.where(user: user).count).to eq(1)
        user.update!(username: "still_works")
      end

      expect(result).not_to be_created
      expect(result.draft).to eq(existing)
      expect(existing.reload.body).to eq("")
      expect(user.reload.username).to eq("still_works")
    end

    it "gives the existing draft when the validation sees it" do
      blind_first_lookup

      expect_existing_inside_a_transaction
    end

    it "gives the existing draft when only the unique index sees it, and the outer transaction goes on" do
      blind_first_lookup
      allow_any_instance_of(OutgoingDraft).to receive(:active?).and_return(false)
      violations = 0
      subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        violations += 1 if payload[:exception]&.first == "ActiveRecord::RecordNotUnique"
      end

      expect_existing_inside_a_transaction
      expect(violations).to eq(1)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end

    it "does not hide other validation failures" do
      expect { described_class.call(user: user, reply_to_message: create(:message, topic: topic), subject: " ") }
        .to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  describe "the limits of a token" do
    let(:token) { ApiToken.issue!(user: user, name: "agent").first }
    let(:limit) { Drafts::TokenLimits::ACTIVE_DRAFTS }

    before do
      limit.times { create(:outgoing_draft, user: user, topic: topic, identity: identity, sender_alias: sender) }
    end

    it "refuses a new draft through a token when the user has 50 that are not sent" do
      expect(limit).to eq(50)
      expect { call(token: token) }.to raise_error(described_class::LimitReached)
      expect(user.outgoing_drafts.count).to eq(limit)
    end

    it "gives an existing draft back at the limit" do
      existing = user.outgoing_drafts.first

      result = described_class.call(user: user, reply_to_message: existing.reply_to_message, token: token)

      expect(result.draft).to eq(existing)
      expect(result).not_to be_created
    end

    it "does not count sent drafts" do
      user.outgoing_drafts.first.update_columns(status: "sent", sent_at: Time.current)

      expect(call(token: token)).to be_created
    end

    it "does not limit a draft made without a token" do
      expect(call).to be_created
      expect(user.outgoing_drafts.count).to eq(limit + 1)
    end
  end

  it "refuses a stored text over max_body_bytes, counting the quote" do
    expect { call(body: "b" * 90, quote: "quoted", max_body_bytes: 100) }.to raise_error(described_class::BodyTooLarge)
    expect { call(body: "b" * 101, max_body_bytes: 100) }.to raise_error(described_class::BodyTooLarge)
    expect(OutgoingDraft.count).to eq(0)

    expect(call(body: "b" * 100, max_body_bytes: 100)).to be_created
  end
end
