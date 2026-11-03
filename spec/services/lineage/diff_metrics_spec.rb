require "rails_helper"

RSpec.describe Lineage::DiffMetrics do
  def parsed(files, subjects = [])
    Lineage::DiffParser::Result.new(
      files: files.map { |path, added, removed|
        Lineage::DiffParser::FileDiff.new(path: path, area: Lineage::DiffParser.area_for(path),
                                          added: Set.new(added), removed: Set.new(removed))
      },
      subjects: subjects
    )
  end

  let(:a) { parsed([ [ "src/backend/x.c", %w[one two], %w[old] ], [ "src/test/regress/sql/t.sql", %w[select], [] ] ], %w[first second third]) }

  it "scores identical diffs as 1.0" do
    m = described_class.compare(a, a)
    expect(m["file_jaccard"]).to eq(1.0)
    expect(m["added_jaccard"]).to eq(1.0)
    expect(m["removed_jaccard"]).to eq(1.0)
    expect(m["size_ratio"]).to eq(1.0)
    expect(m["areas"]["code"]["added_jaccard"]).to eq(1.0)
    expect(m["areas"]["docs"]["added_jaccard"]).to be_nil
  end

  it "scores disjoint diffs as 0.0" do
    b = parsed([ [ "src/backend/y.c", %w[three], [] ] ])
    m = described_class.compare(a, b)
    expect(m["file_jaccard"]).to eq(0.0)
    expect(m["added_jaccard"]).to eq(0.0)
    expect(m["files_only_earlier"]).to eq(2)
    expect(m["files_only_later"]).to eq(1)
  end

  it "detects a remainder series" do
    b = parsed([ [ "src/backend/x.c", %w[one two], %w[old] ] ], %w[second third])
    m = described_class.compare(a, b)
    expect(m["series"]["patches_earlier"]).to eq(3)
    expect(m["series"]["patches_later"]).to eq(2)
    expect(m["series"]["shared_subjects"]).to eq(2)
    expect(m["series"]["subject_shift"]).to eq(-1)
  end
end
