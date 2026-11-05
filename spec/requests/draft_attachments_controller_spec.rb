require 'rails_helper'

RSpec.describe DraftAttachmentsController, type: :request do
  let(:user)   { create(:user) }
  let(:draft)  { create(:outgoing_draft, user: user) }
  let(:stream) { { 'Accept' => 'text/vnd.turbo-stream.html' } }

  before { sign_in_as(user) }

  def upload(name, content, type = 'text/x-diff')
    Rack::Test::UploadedFile.new(StringIO.new(content), type, true, original_filename: name)
  end

  def post_files(*files)
    post draft_attachments_path(draft), params: { files: files }, headers: stream
  end

  describe 'POST create' do
    it 'stores a single file' do
      expect { post_files(upload('fix.patch', "diff\n")) }.to change(DraftAttachment, :count).by(1)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(turbo-stream action="replace" target="draft-attachments-#{draft.id}"))
      expect(response.body).to include('fix.patch')
      expect(response.body).to include(%(data-draft-attachments-remaining-value="#{2.megabytes - 5}"))

      a = draft.draft_attachments.last
      expect(a.file_name).to eq('fix.patch')
      expect(a.content_type).to eq('text/x-diff')
      expect(a.byte_size).to eq(5)
      expect(a.decoded_body).to eq("diff\n")
    end

    it 'stores several files at once' do
      expect {
        post_files(upload('a.patch', 'a'), upload('b.log', 'bb', 'text/plain'))
      }.to change(DraftAttachment, :count).by(2)
      expect(draft.draft_attachments.order(:id).pluck(:file_name)).to eq(%w[a.patch b.log])
    end

    it 'skips empty files' do
      expect { post_files(upload('empty.txt', ''), upload('a.patch', 'a')) }
        .to change(DraftAttachment, :count).by(1)
      expect(draft.draft_attachments.pluck(:file_name)).to eq([ 'a.patch' ])
    end

    it 'sanitizes quotes and control chars in file names' do
      post_files(upload("a\"b\r\nc.txt", 'a'))
      expect(draft.draft_attachments.last.file_name).to eq('a_b__c.txt')
    end

    it 'stores file names with invalid UTF-8' do
      body = "--b\r\nContent-Disposition: form-data; name=\"files[]\"; filename=\"bad\xFF.txt\"\r\n" \
             "Content-Type: text/plain\r\n\r\na\r\n--b--\r\n"
      expect {
        post draft_attachments_path(draft), params: body.b,
             headers: stream.merge('CONTENT_TYPE' => 'multipart/form-data; boundary=b')
      }.to change(DraftAttachment, :count).by(1)
      expect(draft.draft_attachments.last.file_name).to eq('bad_.txt')
    end

    it 'accepts a total of exactly the cap' do
      expect { post_files(upload('big.bin', 'x' * 2.megabytes, 'application/octet-stream')) }
        .to change(DraftAttachment, :count).by(1)
    end

    it 'rejects the whole pick when the sum would exceed the cap' do
      create(:draft_attachment, outgoing_draft: draft, content: 'x', byte_size: 1536.kilobytes)
      expect {
        post_files(upload('a.bin', 'x' * 300.kilobytes), upload('b.bin', 'x' * 300.kilobytes))
      }.not_to change(DraftAttachment, :count)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include('Attachments would total 2.1 MB, limit is 2 MB')
      expect(response.body).to include(%(target="draft-attachments-#{draft.id}"))
    end

    it 'returns 409 while sending' do
      draft.update_columns(status: OutgoingDraft::STATUS_SENDING)
      expect { post_files(upload('a.patch', 'a')) }.not_to change(DraftAttachment, :count)
      expect(response).to have_http_status(:conflict)
      expect(response.body).to include(%(target="draft-attachments-#{draft.id}"))
      expect(response.body).to include('Sending in progress, attachments are read-only')
    end

    it 'refuses a sent draft' do
      draft.update_columns(status: OutgoingDraft::STATUS_SENT)
      expect { post_files(upload('a.patch', 'a')) }.not_to change(DraftAttachment, :count)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include(%(target="draft-attachments-#{draft.id}"))
      expect(response.body).to include('This message has already been sent.')
    end

    it "is not found on another user's draft" do
      other = create(:outgoing_draft)
      post draft_attachments_path(other), params: { files: [ upload('a.patch', 'a') ] }, headers: stream
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'DELETE destroy' do
    let!(:attachment) { create(:draft_attachment, outgoing_draft: draft) }

    it 'removes the file' do
      expect { delete draft_attachment_path(draft, attachment), headers: stream }
        .to change(DraftAttachment, :count).by(-1)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(target="draft-attachments-#{draft.id}"))
    end

    it 'returns 409 while sending' do
      draft.update_columns(status: OutgoingDraft::STATUS_SENDING)
      expect { delete draft_attachment_path(draft, attachment), headers: stream }
        .not_to change(DraftAttachment, :count)
      expect(response).to have_http_status(:conflict)
      expect(response.body).to include(%(target="draft-attachments-#{draft.id}"))
      expect(response.body).to include('Sending in progress, attachments are read-only')
    end

    it 'refuses a sent draft' do
      draft.update_columns(status: OutgoingDraft::STATUS_SENT)
      expect { delete draft_attachment_path(draft, attachment), headers: stream }
        .not_to change(DraftAttachment, :count)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include(%(target="draft-attachments-#{draft.id}"))
      expect(response.body).to include('This message has already been sent.')
    end

    it "is not found for another draft's attachment" do
      foreign = create(:draft_attachment)
      expect { delete draft_attachment_path(draft, foreign), headers: stream }
        .not_to change(DraftAttachment, :count)
      expect(response).to have_http_status(:not_found)
    end
  end
end
