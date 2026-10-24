require "rails_helper"
require "open3"

RSpec.describe PatchBranches::PatchsetExtractor do
  let(:message) { create(:message) }

  def add_attachment(name, content, content_type: "text/plain")
    create(:attachment, message: message, file_name: name, content_type: content_type,
           body: Base64.encode64(content))
  end

  def python3_available?
    return @python3_available if defined?(@python3_available)
    @python3_available = system("python3", "--version", out: File::NULL, err: File::NULL)
  end

  def extract
    files = nil
    Dir.mktmpdir do |dir|
      files = described_class.new(message.reload).extract(dir)
      files = files.map { |f| [ File.basename(f), File.binread(f) ] }
    end
    files
  end

  it "writes patch attachments sorted by series number" do
    add_attachment("0002-b.patch", "two")
    add_attachment("0001-a.patch", "one")
    add_attachment("zzz.patch", "loose")
    expect(extract.map(&:first)).to eq([ "0001-a.patch", "0002-b.patch", "zzz.patch" ])
  end

  it "gunzips .gz attachments" do
    gz = StringIO.new
    Zlib::GzipWriter.wrap(gz) { |w| w.write("patched") }
    add_attachment("fix.patch.gz", gz.string)
    expect(extract).to eq([ [ "fix.patch", "patched" ] ])
  end

  it "refuses gzip output above the cap" do
    stub_const("#{described_class}::MAX_DECOMPRESSED", 100)
    gz = StringIO.new
    Zlib::GzipWriter.wrap(gz) { |w| w.write("x" * 1000) }
    add_attachment("bomb.patch.gz", gz.string)
    Dir.mktmpdir do |dir|
      expect { described_class.new(message.reload).extract(dir) }
        .to raise_error(described_class::Error, /exceeds/)
    end
  end

  it "bunzips .bz2 attachments and caps their output" do
    require "open3"
    compress = "import sys,bz2; sys.stdout.buffer.write(bz2.compress(sys.stdin.buffer.read()))"
    small, = Open3.capture2("python3", "-c", compress, stdin_data: "patched", binmode: true)
    add_attachment("fix.patch.bz2", small)
    expect(extract).to eq([ [ "fix.patch", "patched" ] ])

    stub_const("#{described_class}::MAX_DECOMPRESSED", 100)
    big, = Open3.capture2("python3", "-c", compress, stdin_data: "x" * 100_000, binmode: true)
    add_attachment("bomb.patch.bz2", big)
    Dir.mktmpdir do |dir|
      expect { described_class.new(message.reload).extract(dir) }
        .to raise_error(described_class::Error, /exceeds/)
    end
  end

  it "strips .txt wrappers" do
    add_attachment("fix.patch.txt", "content")
    expect(extract).to eq([ [ "fix.patch", "content" ] ])
  end

  it "ignores non-patch attachments" do
    add_attachment("0001-a.patch", "one")
    add_attachment("screenshot.png", "png data")
    expect(extract.map(&:first)).to eq([ "0001-a.patch" ])
  end

  it "raises when there is nothing to extract" do
    add_attachment("screenshot.png", "png data")
    Dir.mktmpdir do |dir|
      expect { described_class.new(message.reload).extract(dir) }
        .to raise_error(described_class::Error)
    end
  end

  it "raises on corrupt .gz content" do
    add_attachment("fix.patch.gz", "not actually gzip")
    Dir.mktmpdir do |dir|
      expect { described_class.new(message.reload).extract(dir) }
        .to raise_error(described_class::Error)
    end
  end

  it "writes both attachments when filenames collide" do
    add_attachment("a.patch", "one")
    add_attachment("a.patch", "two")
    result = extract
    expect(result.map(&:first)).to match_array([ "a.patch", "1-a.patch" ])
    expect(result.to_h["a.patch"]).to eq("one")
    expect(result.to_h["1-a.patch"]).to eq("two")
  end

  # has_many :attachments carries no order, so postgres may hand back colliding
  # names either way round and the renaming would pick a different winner
  it "renames collisions by attachment id, whatever order the rows arrive in" do
    add_attachment("a.patch", "one")
    add_attachment("a.patch", "two")
    reversed = message.reload.attachments.to_a.reverse
    allow_any_instance_of(Message).to receive(:attachments).and_return(reversed)

    result = extract

    expect(result.to_h["a.patch"]).to eq("one")
    expect(result.to_h["1-a.patch"]).to eq("two")
  end

  it "keeps only the highest version when a message carries two series versions" do
    add_attachment("0001-a.patch", "old one")
    add_attachment("0002-b.patch", "old two")
    add_attachment("v2-0001-a.patch", "new one")
    add_attachment("v2-0002-b.patch", "new two")
    expect(extract).to eq([ [ "v2-0001-a.patch", "new one" ],
                            [ "v2-0002-b.patch", "new two" ] ])
  end

  it "raises on duplicate series numbers without version markers" do
    add_attachment("0001-a.patch", "one")
    add_attachment("0001-b.patch", "two")
    Dir.mktmpdir do |dir|
      expect { described_class.new(message.reload).extract(dir) }
        .to raise_error(described_class::Error, /ambiguous/)
    end
  end

  it "keeps a versioned series intact when there are no duplicates" do
    add_attachment("v3-0002-b.patch", "two")
    add_attachment("v3-0001-a.patch", "one")
    expect(extract.map(&:first)).to eq([ "v3-0001-a.patch", "v3-0002-b.patch" ])
  end

  it "does not treat a mid-name v token as a version marker" do
    add_attachment("0001-add-v2-protocol.patch", "one")
    add_attachment("0001-other.patch", "two")
    Dir.mktmpdir do |dir|
      expect { described_class.new(message.reload).extract(dir) }
        .to raise_error(described_class::Error, /no version markers/)
    end
  end

  it "raises when a reroll covers only part of the series" do
    add_attachment("0001-a.patch", "old one")
    add_attachment("0002-b.patch", "old two")
    add_attachment("v2-0001-a.patch", "new one")
    Dir.mktmpdir do |dir|
      expect { described_class.new(message.reload).extract(dir) }
        .to raise_error(described_class::Error, /does not cover/)
    end
  end

  it "does not count date-prefixed names as series numbers" do
    add_attachment("2024-fix-a.patch", "a")
    add_attachment("2024-fix-b.patch", "b")
    expect(extract.map(&:first)).to match_array([ "2024-fix-a.patch", "2024-fix-b.patch" ])
  end

  it "drops loose attachments with a different version marker" do
    add_attachment("0001-a.patch", "old")
    add_attachment("v2-0001-a.patch", "new")
    add_attachment("cleanup-v1.patch", "old loose")
    add_attachment("hotfix-v1", "old loose", content_type: "text/x-patch")
    add_attachment("extra.patch", "kept")
    expect(extract.map(&:first)).to match_array([ "v2-0001-a.patch", "extra.patch" ])
  end

  it "round-trips a .patch.bz2 attachment" do
    skip "python3 not available" unless python3_available?

    out, status = Open3.capture2("python3", "-c",
      "import sys,bz2; sys.stdout.buffer.write(bz2.compress(sys.stdin.buffer.read()))",
      stdin_data: "bz2 patch content", binmode: true)
    raise "failed to build test fixture" unless status.success?

    add_attachment("fix.patch.bz2", out)
    expect(extract).to eq([ [ "fix.patch", "bz2 patch content" ] ])
  end

  it "raises on a blank attachment body" do
    create(:attachment, message: message, file_name: "0001-a.patch", body: "")
    Dir.mktmpdir do |dir|
      expect { described_class.new(message.reload).extract(dir) }
        .to raise_error(described_class::Error)
    end
  end

  it "falls back to an attachment-id name for degenerate filenames" do
    attachment = add_attachment(".txt", "content", content_type: "text/x-patch")
    expect(extract).to eq([ [ "attachment-#{attachment.id}.patch", "content" ] ])
  end
end
