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

  def version_in_stream
    Nokogiri::HTML(response.body).at_css('[data-reply-composer-target="version"]')['data-version']
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

    it 'refuses an oversized pick before reading any of the files' do
      create(:draft_attachment, outgoing_draft: draft, content: 'x', byte_size: 1536.kilobytes)
      expect_any_instance_of(ActionDispatch::Http::UploadedFile).not_to receive(:read)
      expect(Drafts::AttachmentAdder).not_to receive(:call)

      expect {
        post_files(upload('a.bin', 'x' * 300.kilobytes), upload('b.bin', 'x' * 300.kilobytes))
      }.not_to change(DraftAttachment, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include('Attachments would total 2.1 MB, limit is 2 MB')
    end

    it 'does not read the files while sending' do
      draft.update_columns(status: OutgoingDraft::STATUS_SENDING)
      expect_any_instance_of(ActionDispatch::Http::UploadedFile).not_to receive(:read)

      post_files(upload('a.bin', 'x' * 3.megabytes))

      expect(response).to have_http_status(:conflict)
    end

    it 'stores a plain content type' do
      post_files(upload('a.txt', 'a', 'Multipart/Mixed; boundary=abc'), upload('b.txt', 'b', 'text/plain; name="evil.exe"'))

      expect(draft.draft_attachments.order(:id).pluck(:content_type)).to eq(%w[application/octet-stream text/plain])
    end

    it 'gives the page the new version of the draft' do
      draft.update_columns(updated_at: 1.hour.ago)
      was = draft.reload.version

      post_files(upload('fix.patch', "diff\n"))

      expect(version_in_stream).to eq(draft.reload.version)
      expect(version_in_stream).not_to eq(was)
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

    it 'gives the page the new version of the draft' do
      draft.update_columns(updated_at: 1.hour.ago)
      was = draft.reload.version

      delete draft_attachment_path(draft, attachment), headers: stream

      expect(version_in_stream).to eq(draft.reload.version)
      expect(version_in_stream).not_to eq(was)
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

  describe 'GET show' do
    let(:bytes) { (0..255).map(&:chr).join.b }
    let!(:attachment) {
      create(:draft_attachment, outgoing_draft: draft, file_name: 'blob.bin',
             content_type: 'application/x-thing', content: bytes)
    }

    def expect_download(name)
      expect(response).to have_http_status(:ok)
      expect(response.headers['Content-Disposition']).to start_with(%(attachment; filename="#{name}"))
      expect(response.headers['X-Content-Type-Options']).to eq('nosniff')
      expect(response.headers['Cache-Control']).to eq('private, no-store')
    end

    it 'gives the owner the bytes as a download' do
      get draft_attachment_path(draft, attachment)

      expect_download('blob.bin')
      expect(response.body.b).to eq(bytes)
      expect(response.headers['Content-Type']).to eq('application/octet-stream')
    end

    it 'serves stored HTML as a plain text download' do
      html = create(:draft_attachment, outgoing_draft: draft, file_name: 'page.html',
                    content_type: 'text/html; charset=utf-7', content: '<script>alert(1)</script>')

      get draft_attachment_path(draft, html)

      expect_download('page.html')
      expect(response.headers['Content-Type']).to eq('text/plain; charset=utf-8')
      expect(response.body).to eq('<script>alert(1)</script>')
    end

    it 'does not take the type of a stored row that is not text' do
      svg = create(:draft_attachment, outgoing_draft: draft, file_name: 'x.svg',
                   content_type: 'image/svg+xml', content: '<svg/>')

      get draft_attachment_path(draft, svg)

      expect(response.headers['Content-Type']).to eq('application/octet-stream')
    end

    it 'cleans the name of a stored row' do
      attachment.update_columns(file_name: "a\u202Eb\"c.txt")

      get draft_attachment_path(draft, attachment)

      expect_download('ab_c.txt')
    end

    it 'works on a sent draft' do
      draft.update_columns(status: OutgoingDraft::STATUS_SENT)

      get draft_attachment_path(draft, attachment)

      expect_download('blob.bin')
    end

    it 'is not found for another user' do
      sign_in_as(create(:user))

      get draft_attachment_path(draft, attachment)

      expect(response).to have_http_status(:not_found)
    end

    it "is not found for another draft's attachment" do
      get draft_attachment_path(draft, create(:draft_attachment))

      expect(response).to have_http_status(:not_found)
    end

    it 'redirects to sign-in when signed out' do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(nil)
      allow_any_instance_of(ApplicationController).to receive(:user_signed_in?).and_return(false)

      get draft_attachment_path(draft, attachment)

      expect(response).to redirect_to(new_session_path)
      expect(response.body).not_to include(bytes)
    end
  end
end
