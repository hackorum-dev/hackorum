require 'rails_helper'

RSpec.describe DraftsController, type: :request do
  let(:user) { create(:user) }
  let!(:identity) {
    create(:identity, user: user, email: 'a@b',
           refresh_token: 'r', send_authorized_at: 1.hour.ago)
  }
  let!(:sender) { create(:alias, user: user, email: 'a@b', name: 'Alice') }
  let(:list)    { create(:mailing_list, post_address: 'real@list.example') }
  let(:topic)   { create(:topic, mailing_lists: [ list ]) }
  let(:parent)  { create(:message, topic: topic, subject: 'Hi') }

  before { sign_in_as(user) }

  describe 'POST /drafts' do
    it 'creates a draft' do
      expect {
        post drafts_path, params: { reply_to_message_id: parent.id }, as: :json
      }.to change(OutgoingDraft, :count).by(1)
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json['id']).to be_present
    end

    it 'returns existing draft on second post' do
      post drafts_path, params: { reply_to_message_id: parent.id }, as: :json
      first_id = JSON.parse(response.body)['id']
      post drafts_path, params: { reply_to_message_id: parent.id }, as: :json
      second_id = JSON.parse(response.body)['id']
      expect(first_id).to eq(second_id)
    end

    it 'sets default subject by stripping a single Re:/Fwd:/Aw: prefix' do
      parent.update!(subject: 'RE: Hello world')
      post drafts_path, params: { reply_to_message_id: parent.id }, as: :json
      draft = OutgoingDraft.last
      expect(draft.subject).to eq('Re: Hello world')
    end

    it 'forbids when user has no send-authorized identity' do
      identity.update!(send_revoked_at: Time.current)
      post drafts_path, params: { reply_to_message_id: parent.id }, as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it 'errors when no alias matches the identity email' do
      sender.update!(email: 'different@b')
      post drafts_path, params: { reply_to_message_id: parent.id }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'picks the named alias over a Noname alias for the same identity email' do
      create(:alias, user: user, email: 'a@b', name: 'Noname', sender_count: 50)

      post drafts_path, params: { reply_to_message_id: parent.id }, as: :json
      expect(response).to have_http_status(:ok)

      draft = OutgoingDraft.find(JSON.parse(response.body)['id'])
      expect(draft.sender_alias).to eq(sender)
      expect(draft.sender_alias.name).to eq('Alice')
    end

    it 'turbo_stream response replaces topic-drafts-sidebar' do
      post drafts_path,
           params: { reply_to_message_id: parent.id },
           headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq(Mime[:turbo_stream].to_s)
      expect(response.body).to include(%(turbo-stream action="replace" target="topic-drafts-sidebar"))
      expect(response.body).to include('drafts-list')
    end
  end

  describe 'POST /drafts after a sent draft to the same parent' do
    let!(:sent_msg) {
      create(:message, topic: topic, sender: sender, sender_person_id: sender.person_id,
             reply_to: parent, subject: 'Re: Hi', body: 'b')
    }
    let!(:sent_draft) {
      create(:outgoing_draft,
             user: user, topic: topic, reply_to_message: parent,
             identity: identity, sender_alias: sender,
             status: 'sent', sent_message_id: sent_msg.id, sent_at: 1.minute.ago)
    }

    it 'creates a new active draft (does not return the sent one)' do
      expect {
        post drafts_path, params: { reply_to_message_id: parent.id }, as: :json
      }.to change(OutgoingDraft, :count).by(1)
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json['id']).not_to eq(sent_draft.id)
      new_draft = OutgoingDraft.find(json['id'])
      expect(new_draft).to be_idle
    end
  end

  describe 'PATCH /drafts/:id' do
    let(:draft) {
      create(:outgoing_draft, user: user, topic: topic,
             reply_to_message: parent, identity: identity, sender_alias: sender)
    }

    it 'updates body and subject' do
      patch draft_path(draft), params: {
        outgoing_draft: { body: 'new body', subject: 'Re: new subject' }
      }
      expect(response).to have_http_status(:no_content)
      expect(draft.reload.body).to eq('new body')
      expect(draft.subject).to eq('Re: new subject')
    end

    it 'returns 409 when sending' do
      draft.update!(status: 'sending', sending_started_at: 1.second.ago)
      patch draft_path(draft), params: { outgoing_draft: { body: 'x' } }
      expect(response).to have_http_status(:conflict)
    end

    it "forbids editing another user's draft" do
      other = create(:outgoing_draft)
      patch draft_path(other), params: { outgoing_draft: { body: 'x' } }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'DELETE /drafts/:id' do
    let!(:draft) {
      create(:outgoing_draft, user: user, topic: topic,
             reply_to_message: parent, identity: identity, sender_alias: sender)
    }

    it 'destroys' do
      expect { delete draft_path(draft) }.to change(OutgoingDraft, :count).by(-1)
      expect(response).to have_http_status(:no_content)
    end

    it 'returns a turbo_stream that empties the draft frame' do
      delete draft_path(draft), headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq(Mime[:turbo_stream].to_s)
      expect(response.body).to include(%(turbo-stream action="replace" target="draft-#{parent.id}"))
    end

    it 'turbo_stream response also replaces topic-drafts-sidebar' do
      delete draft_path(draft), headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
      expect(response.body).to include(%(turbo-stream action="replace" target="topic-drafts-sidebar"))
    end
  end

  describe 'GET /drafts/:id/confirm' do
    let(:draft) {
      create(:outgoing_draft, user: user, topic: topic,
             reply_to_message: parent, identity: identity, sender_alias: sender)
    }

    it 'renders the confirm modal with resolved recipient' do
      with_env('HACKORUM_DEV_REPLY_TO' => 'test@example.com') do
        get confirm_draft_path(draft)
        expect(response).to be_successful
        expect(response.body).to include('test@example.com')
      end
    end

    it 'returns 422 when dev override is missing' do
      with_env('HACKORUM_DEV_REPLY_TO' => nil) do
        get confirm_draft_path(draft)
        expect(response).to have_http_status(:unprocessable_entity)
      end
    end
  end

  describe 'POST /drafts/:id/send_now' do
    let(:draft) {
      create(:outgoing_draft, user: user, topic: topic,
             reply_to_message: parent, identity: identity, sender_alias: sender)
    }

    it 'transitions to sending and runs the job inline' do
      expect(SendOutgoingMessageJob).to receive(:perform_now).with(draft.id)
      post send_now_draft_path(draft)
      draft.reload
      expect(draft.status).to eq('sending')
      expect(draft.sending_started_at).not_to be_nil
    end

    it 'returns 409 when already sending' do
      draft.update!(status: 'sending', sending_started_at: 1.second.ago)
      post send_now_draft_path(draft)
      expect(response).to have_http_status(:conflict)
    end
  end

  describe 'GET /drafts (index)' do
    let!(:idle_draft)    { create(:outgoing_draft, user: user, topic: topic,
                                  reply_to_message: parent, identity: identity, sender_alias: sender) }
    let!(:other_parent)  { create(:message, topic: topic, subject: 'Other') }
    let!(:sent_draft)    {
      msg = create(:message, topic: topic, sender: sender, sender_person_id: sender.person_id,
                   reply_to: other_parent, subject: 'Re: Other', body: 'b')
      create(:outgoing_draft,
             user: user, topic: topic, reply_to_message: other_parent,
             identity: identity, sender_alias: sender,
             status: 'sent', sent_message_id: msg.id, sent_at: 1.minute.ago)
    }
    let!(:other_user_draft) { create(:outgoing_draft) }

    it 'lists only current user drafts across all states' do
      get drafts_path
      expect(response).to be_successful
      expect(response.body).to include(idle_draft.subject)
      expect(response.body).to include(sent_draft.subject)
      expect(response.body).not_to include(other_user_draft.subject)
    end

    it 'filters to sent only with ?state=sent' do
      get drafts_path(state: 'sent')
      expect(response.body).to include(sent_draft.subject)
      expect(response.body).not_to include(idle_draft.subject)
    end
  end

  describe 'GET /drafts/:id (show)' do
    let(:msg) {
      create(:message, topic: topic, sender: sender, sender_person_id: sender.person_id,
             reply_to: parent, subject: 'Re: Hi', body: 'b')
    }
    let(:sent_draft) {
      create(:outgoing_draft,
             user: user, topic: topic, reply_to_message: parent,
             identity: identity, sender_alias: sender,
             status: 'sent', sent_message_id: msg.id, sent_at: 1.minute.ago,
             subject: 'Re: Hi', body: 'hello there')
    }

    it 'renders read-only view of a sent draft' do
      get draft_path(sent_draft)
      expect(response).to be_successful
      expect(response.body).to include('Re: Hi')
      expect(response.body).to include('hello there')
    end

    it 'returns 404 for another user' do
      other = create(:outgoing_draft, status: 'sent', sent_at: 1.minute.ago)
      get draft_path(other)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'mutating actions on a sent draft' do
    let(:sent_draft) {
      create(:outgoing_draft,
             user: user, topic: topic, reply_to_message: parent,
             identity: identity, sender_alias: sender,
             status: 'sent', sent_at: 1.minute.ago)
    }

    it 'rejects PATCH with 422' do
      patch draft_path(sent_draft), params: { outgoing_draft: { body: 'x' } }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'rejects DELETE with 422' do
      delete draft_path(sent_draft)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'rejects POST send_now with 422' do
      post send_now_draft_path(sent_draft)
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'full send flow' do
    it 'send_now marks draft sent and it appears in index and show' do
      draft = create(:outgoing_draft,
                     user: user, topic: topic,
                     reply_to_message: parent,
                     identity: identity, sender_alias: sender,
                     subject: 'Re: hi', body: 'hello',
                     status: 'idle')

      builder = Outgoing::MessageBuilder::Result.new(
        encoded: "raw", message_id: "<flow@x>",
        subject: "Re: hi", recipient: "to@x")
      allow(OAuth::TokenRefresher).to receive(:call)
      allow(Outgoing::MessageBuilder).to receive(:build).and_return(builder)
      allow(Gmail::SendClient).to receive(:send_raw).and_return({ "id" => "g" })

      post send_now_draft_path(draft)
      draft.reload
      expect(draft).to be_sent
      expect(draft.sent_message_id).to be_present

      get drafts_path(state: 'sent')
      expect(response.body).to include('Re: hi')

      get draft_path(draft)
      expect(response.body).to include('Re: hi')
      expect(response.body).to include('hello')
    end
  end
end
