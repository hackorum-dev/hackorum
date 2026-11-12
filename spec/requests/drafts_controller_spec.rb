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

    it 'answers with the new version of the draft' do
      draft.update_columns(updated_at: 1.hour.ago)
      was = draft.reload.version

      patch draft_path(draft), params: { outgoing_draft: { body: 'new body' } }

      expect(response).to have_http_status(:no_content)
      expect(response.headers['X-Draft-Version']).to eq(draft.reload.version)
      expect(response.headers['X-Draft-Version']).not_to eq(was)
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
        get confirm_draft_path(draft, version: draft.version)
        expect(response).to be_successful
        expect(response.body).to include('test@example.com')
        expect(response.body).not_to include('<strong>Cc</strong>')
      end
    end

    it 'returns 422 when dev override is missing' do
      with_env('HACKORUM_DEV_REPLY_TO' => nil) do
        get confirm_draft_path(draft, version: draft.version)
        expect(response).to have_http_status(:unprocessable_entity)
      end
    end

    it 'renders To and Cc rows when the resolver returns cc recipients' do
      allow(Outgoing::RecipientResolver).to receive(:for).and_return(
        Outgoing::RecipientResolver::Recipients.new(
          to: [ 'Bob <bob@x>' ], cc: [ 'list@x', 'Carol <carol@x>' ]))
      get confirm_draft_path(draft, version: draft.version)
      expect(response).to be_successful
      expect(response.body).to include('bob@x')
      expect(response.body).to include('list@x')
      expect(response.body).to include('<strong>Cc</strong>')
      expect(response.body).to include('Send to 3 recipients')
      expect(response.body).to include('Bob &lt;bob@x&gt;')
    end

    it 'lists attachments with the total' do
      create(:draft_attachment, outgoing_draft: draft, file_name: 'fix.patch', content: 'abc')
      with_env('HACKORUM_DEV_REPLY_TO' => 'test@example.com') do
        get confirm_draft_path(draft, version: draft.version)
        expect(response.body).to include('<strong>Attachments</strong>')
        expect(response.body).to include('fix.patch')
      end
    end

    it 'has no attachments row without attachments' do
      with_env('HACKORUM_DEV_REPLY_TO' => 'test@example.com') do
        get confirm_draft_path(draft, version: draft.version)
        expect(response.body).not_to include('<strong>Attachments</strong>')
      end
    end

    it 'is refused with a version the draft no longer has' do
      stale = draft.version
      draft.update_columns(body: 'text via the API', updated_at: 1.second.from_now)

      with_env('HACKORUM_DEV_REPLY_TO' => 'test@example.com') do
        get confirm_draft_path(draft, version: stale)
      end

      expect(response).to have_http_status(:conflict)
      expect(response.body).to eq(DraftsController::CHANGED_ELSEWHERE)
      expect(response.body).not_to include('turbo-frame', 'via the API')
    end

    it 'is refused without a version' do
      with_env('HACKORUM_DEV_REPLY_TO' => 'test@example.com') do
        get confirm_draft_path(draft)
      end

      expect(response).to have_http_status(:conflict)
      expect(response.body).to eq(DraftsController::CHANGED_ELSEWHERE)
    end

    it 'shows what is about to be sent: text, API labels, each file with its size, and the version' do
      token = ApiToken.issue!(user: user, name: 'agent <b>one</b>').first
      other = ApiToken.issue!(user: user, name: 'laptop').first
      draft.update!(body: "first line\n  <script>x</script> & more\nlast line",
                    created_via_token: token, last_edited_via_token: other)
      patch_file = create(:draft_attachment, outgoing_draft: draft, file_name: 'fix.patch', content: 'abc')
      create(:draft_attachment, outgoing_draft: draft, file_name: 'big.log', content: 'x' * 2048)

      with_env('HACKORUM_DEV_REPLY_TO' => 'test@example.com') do
        get confirm_draft_path(draft, version: draft.reload.version)
      end

      expect(response).to be_successful
      html = Nokogiri::HTML(response.body)
      expect(html.at_css('.confirm-body').text).to eq("first line\n  <script>x</script> & more\nlast line")
      expect(response.body).to include('&lt;script&gt;x&lt;/script&gt; &amp; more')
      expect(html.css('.confirm-via').map(&:text))
        .to eq([ 'Drafted via API (agent <b>one</b>)', 'Edited via API (laptop)' ])
      expect(html.css('.confirm-attachment').map { |li| li.text.squish })
        .to eq([ 'fix.patch 3 Bytes', 'big.log 2 KB' ])
      expect(html.at_css('.confirm-attachment a')['href']).to eq(draft_attachment_path(draft, patch_file))
      form = html.at_css(%(form[action="#{send_now_draft_path(draft)}"]))
      expect(form.at_css('input[name="version"]')['value']).to eq(draft.reload.version)
    end
  end

  describe 'GET /drafts/:id/edit' do
    let(:draft) {
      create(:outgoing_draft, user: user, topic: topic,
             reply_to_message: parent, identity: identity, sender_alias: sender)
    }

    it 'carries the version of the draft, outside the autosave form' do
      get edit_draft_path(draft)
      field = Nokogiri::HTML(response.body).at_css('[data-reply-composer-target="version"]')
      expect(field['data-version']).to eq(draft.reload.version)
      expect(field.ancestors('form')).to be_empty
    end

    it 'renders the attachments block outside the autosave form' do
      create(:draft_attachment, outgoing_draft: draft, file_name: 'fix.patch', content: 'abc')
      get edit_draft_path(draft)
      expect(response).to be_successful
      html = Nokogiri::HTML(response.body)
      block = html.at_css("#draft-attachments-#{draft.id}")
      expect(block).to be_present
      expect(block.ancestors('form')).to be_empty
      expect(block.text).to include('fix.patch', 'Attach files', 'of 2 MB')
    end
  end

  describe 'POST /drafts/:id/send_now' do
    let(:draft) {
      create(:outgoing_draft, user: user, topic: topic,
             reply_to_message: parent, identity: identity, sender_alias: sender)
    }

    it 'transitions to sending and runs the job inline' do
      expect(SendOutgoingMessageJob).to receive(:perform_now).with(draft.id)
      post send_now_draft_path(draft), params: { version: draft.version }
      draft.reload
      expect(draft.status).to eq('sending')
      expect(draft.sending_started_at).not_to be_nil
    end

    it 'returns 409 when already sending' do
      draft.update!(status: 'sending', sending_started_at: 1.second.ago)
      post send_now_draft_path(draft), params: { version: draft.version }
      expect(response).to have_http_status(:conflict)
      expect(response.body).to eq('Draft is already being sent.')
    end

    it 'does not send with a version the draft no longer has' do
      stale = draft.version
      draft.update_columns(body: 'changed elsewhere', updated_at: 1.second.from_now)
      expect(SendOutgoingMessageJob).not_to receive(:perform_now)

      post send_now_draft_path(draft), params: { version: stale }

      expect(response).to have_http_status(:conflict)
      expect(response.body).to eq(DraftsController::CHANGED_ELSEWHERE)
      expect(draft.reload).to have_attributes(status: 'idle', sending_started_at: nil)
    end

    it 'does not send without a version' do
      expect(SendOutgoingMessageJob).not_to receive(:perform_now)

      post send_now_draft_path(draft)

      expect(response).to have_http_status(:conflict)
      expect(response.body).to eq(DraftsController::CHANGED_ELSEWHERE)
      expect(draft.reload).to be_idle
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

    it 'lists attachments of a sent draft, each a download' do
      file = create(:draft_attachment, outgoing_draft: sent_draft, file_name: 'fix.patch', content: 'abc')
      get draft_path(sent_draft)
      html = Nokogiri::HTML(response.body)
      item = html.css('.sent-attachments li').find { |li| li.text.include?('fix.patch') }
      expect(item).to be_present
      expect(item.text).to include('3 Bytes')
      expect(item.css('a').map { |a| a['href'] }).to eq([ draft_attachment_path(sent_draft, file) ])
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

      post send_now_draft_path(draft), params: { version: draft.version }
      draft.reload
      expect(draft).to be_sent
      expect(draft.sent_message_id).to be_present
      expect(Gmail::SendClient).to have_received(:send_raw).once

      get drafts_path(state: 'sent')
      expect(response.body).to include('Re: hi')

      get draft_path(draft)
      expect(response.body).to include('Re: hi')
      expect(response.body).to include('hello')
    end
  end

  describe 'a draft changed after the confirm frame was shown' do
    it 'sends nothing' do
      draft = create(:outgoing_draft,
                     user: user, topic: topic,
                     reply_to_message: parent,
                     identity: identity, sender_alias: sender,
                     subject: 'Re: hi', body: 'hello',
                     status: 'idle')
      token = ApiToken.issue!(user: user, name: 'agent').first

      allow(OAuth::TokenRefresher).to receive(:call)
      allow(Outgoing::MessageBuilder).to receive(:build)
      allow(Gmail::SendClient).to receive(:send_raw)

      with_env('HACKORUM_DEV_REPLY_TO' => 'test@example.com') do
        get confirm_draft_path(draft, version: draft.reload.version)
      end
      expect(response).to be_successful
      form = Nokogiri::HTML(response.body).at_css(%(form[action="#{send_now_draft_path(draft)}"]))
      confirmed = form.at_css('input[name="version"]')['value']

      draft.update_columns(subject: 'Re: other', body: 'not what was read',
                           last_edited_via_token_id: token.id, updated_at: 1.second.from_now)
      result = Drafts::AttachmentAdder.call(
        draft: draft, token: token,
        files: [ { name: 'new.sh', content_type: 'text/plain', bytes: 'rm -rf' } ])
      expect(result).to be_added

      expect { post send_now_draft_path(draft), params: { version: confirmed } }
        .not_to change(Message, :count)

      expect(response).to have_http_status(:conflict)
      expect(response.body).to eq(DraftsController::CHANGED_ELSEWHERE)
      expect(OAuth::TokenRefresher).not_to have_received(:call)
      expect(Outgoing::MessageBuilder).not_to have_received(:build)
      expect(Gmail::SendClient).not_to have_received(:send_raw)
      expect(draft.reload).to have_attributes(status: 'idle', sending_started_at: nil, sent_message_id: nil)
    end
  end

  describe 'API markers' do
    let(:made_by) { ApiToken.issue!(user: user, name: 'agent <b>one</b>').first }
    let(:edited_by) { ApiToken.issue!(user: user, name: 'laptop').first }
    let(:draft) {
      create(:outgoing_draft, user: user, topic: topic,
             reply_to_message: parent, identity: identity, sender_alias: sender,
             subject: 'Re: Hi', body: 'text')
    }

    def meta
      get edit_draft_path(draft)
      expect(response).to be_successful
      Nokogiri::HTML(response.body).at_css('.composer-meta')
    end

    it 'has no label on a draft made in the browser' do
      post drafts_path, params: { reply_to_message_id: parent.id }, as: :json
      made = OutgoingDraft.find(JSON.parse(response.body)['id'])

      expect(made.created_via_token_id).to be_nil
      get edit_draft_path(made)
      expect(response.body).not_to include('via API')
    end

    it 'says which token drafted it, with the name escaped' do
      draft.update!(created_via_token: made_by)

      expect(meta.css('.composer-via').map(&:text)).to eq([ 'Drafted via API (agent <b>one</b>)' ])
      expect(response.body).to include('Drafted via API (agent &lt;b&gt;one&lt;/b&gt;)')
      expect(response.body).not_to include('Edited via API')
    end

    it 'says which token edited it last' do
      draft.update!(last_edited_via_token: edited_by)

      expect(meta.css('.composer-via').map(&:text)).to eq([ 'Edited via API (laptop)' ])
    end

    it 'shows both, and keeps the name of a revoked token' do
      draft.update!(created_via_token: made_by, last_edited_via_token: edited_by)
      edited_by.revoke!

      expect(meta.css('.composer-via').map(&:text))
        .to eq([ 'Drafted via API (agent <b>one</b>)', 'Edited via API (laptop)' ])
    end

    it 'clears the edited marker on a browser edit and keeps the drafted one' do
      draft.update!(created_via_token: made_by, last_edited_via_token: edited_by)

      patch draft_path(draft), params: { outgoing_draft: { body: 'changed in the browser' } }

      expect(response).to have_http_status(:no_content)
      expect(draft.reload).to have_attributes(body: 'changed in the browser', last_edited_via_token_id: nil,
                                              created_via_token_id: made_by.id)
      expect(meta.css('.composer-via').map(&:text)).to eq([ 'Drafted via API (agent <b>one</b>)' ])
    end

    it 'keeps the edited marker when a browser save changes nothing' do
      draft.update!(last_edited_via_token: edited_by)

      patch draft_path(draft), params: { outgoing_draft: { body: 'text', subject: 'Re: Hi' } }

      expect(response).to have_http_status(:no_content)
      expect(draft.reload.last_edited_via_token_id).to eq(edited_by.id)
    end

    it 'shows the labels on the page of a sent draft' do
      draft.update!(created_via_token: made_by, last_edited_via_token: edited_by, status: 'sent', sent_at: 1.minute.ago)

      get draft_path(draft)

      expect(response.body).to include('Drafted via API (agent &lt;b&gt;one&lt;/b&gt;)', 'Edited via API (laptop)')
    end

    it 'loses the markers when the token rows go away' do
      draft.update!(created_via_token: made_by, last_edited_via_token: edited_by)

      ApiToken.where(user_id: user.id).delete_all

      expect(draft.reload).to have_attributes(created_via_token_id: nil, last_edited_via_token_id: nil)
      get edit_draft_path(draft)
      expect(response.body).not_to include('via API')
    end
  end
end
