require 'rails_helper'

RSpec.describe PatchFile, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:attachment) }
  end

  describe "validations" do
    subject { build(:patch_file) }

    it "is valid with valid attributes" do
      expect(subject).to be_valid
    end

    it "requires a filename" do
      subject.filename = nil
      expect(subject).not_to be_valid
    end

    it "requires unique filename per attachment" do
      existing = create(:patch_file, filename: "src/test.c")
      duplicate = build(:patch_file, attachment: existing.attachment, filename: "src/test.c")
      expect(duplicate).not_to be_valid
    end

    it "validates status values" do
      subject.status = 'invalid'
      expect(subject).not_to be_valid

      %w[added modified deleted renamed].each do |status|
        subject.status = status
        expect(subject).to be_valid
      end
    end
  end

  describe "scopes" do
    let!(:contrib_file) { create(:patch_file, :contrib_file) }
    let!(:backend_file) { create(:patch_file, :backend_file) }
    let!(:other_file) { create(:patch_file, filename: "doc/README") }

    describe ".contrib_files" do
      it "returns only files in contrib directory" do
        expect(PatchFile.contrib_files).to include(contrib_file)
        expect(PatchFile.contrib_files).not_to include(backend_file, other_file)
      end
    end

    describe ".backend_files" do
      it "returns only files in src/backend directory" do
        expect(PatchFile.backend_files).to include(backend_file)
        expect(PatchFile.backend_files).not_to include(contrib_file, other_file)
      end
    end

    describe ".in_directory" do
      it "returns files in specified directory" do
        doc_files = PatchFile.in_directory("doc")
        expect(doc_files).to include(other_file)
        expect(doc_files).not_to include(contrib_file, backend_file)
      end
    end
  end

  describe "factory" do
    it "creates valid patch files" do
      patch_file = create(:patch_file)
      expect(patch_file).to be_persisted
      expect(patch_file.filename).to be_present
      expect(patch_file.attachment).to be_present
    end

    it "creates contrib files" do
      contrib_file = create(:patch_file, :contrib_file)
      expect(contrib_file.filename).to start_with("contrib/")
    end
  end
end
