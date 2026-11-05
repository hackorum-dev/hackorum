require 'rails_helper'

RSpec.describe DraftAttachment do
  it 'requires file_name, body and byte_size' do
    a = described_class.new(outgoing_draft: create(:outgoing_draft))
    expect(a).not_to be_valid
    expect(a.errors.attribute_names).to include(:file_name, :body, :byte_size)
  end

  it 'decodes the stored body back to the original bytes' do
    bytes = (0..255).map(&:chr).join.b
    a = create(:draft_attachment, content: bytes)
    expect(a.decoded_body.b).to eq(bytes)
  end

  it 'lists without loading bodies, oldest first' do
    draft = create(:outgoing_draft)
    first = create(:draft_attachment, outgoing_draft: draft)
    second = create(:draft_attachment, outgoing_draft: draft)
    listed = draft.draft_attachments.listing.to_a
    expect(listed.map(&:id)).to eq([ first.id, second.id ])
    expect(listed.first.has_attribute?(:body)).to be false
  end

  describe 'on the draft' do
    let(:draft) { create(:outgoing_draft) }

    it 'sums byte sizes' do
      expect(draft.attachment_bytes).to eq(0)
      create(:draft_attachment, outgoing_draft: draft, content: 'abc')
      create(:draft_attachment, outgoing_draft: draft, content: 'de')
      expect(draft.attachment_bytes).to eq(5)
    end

    it 'caps at 2 MB' do
      expect(OutgoingDraft::MAX_ATTACHMENT_BYTES).to eq(2.megabytes)
    end

    it 'goes away with the draft' do
      create(:draft_attachment, outgoing_draft: draft)
      expect { draft.destroy! }.to change(DraftAttachment, :count).by(-1)
    end
  end
end
