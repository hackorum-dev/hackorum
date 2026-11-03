require "rails_helper"

RSpec.describe LineageHelper, type: :helper do
  let(:ordinals) { { 42 => 7 } }
  let(:sha) { "a" * 40 }

  describe "#lineage_text" do
    it "escapes html" do
      expect(helper.lineage_text("a <b> c", ordinals)).to eq("a &lt;b&gt; c")
    end

    it "links message tokens by ordinal" do
      expect(helper.lineage_text("see [msg:42]", ordinals)).to eq('see <a href="#message-42">#7</a>')
    end

    it "falls back to the id for unknown messages" do
      expect(helper.lineage_text("see [msg:99]", ordinals)).to eq('see <a href="#message-99">#99</a>')
    end

    it "links commit tokens" do
      html = helper.lineage_text("in [commit:#{sha}]", ordinals)
      expect(html).to include(%(href="https://github.com/postgres/postgres/commit/#{sha}"))
      expect(html).to include('target="_blank"')
      expect(html).to include('rel="noopener"')
      expect(html).to include(">aaaaaaaaaa</a>")
    end

    it "is html safe and handles nil" do
      expect(helper.lineage_text("x", ordinals)).to be_html_safe
      expect(helper.lineage_text(nil, ordinals)).to eq("")
    end
  end

  describe "#lineage_plain" do
    it "replaces tokens with plain text" do
      expect(helper.lineage_plain("[msg:42] [msg:99] [commit:#{sha}] <x>", ordinals)).to eq("#7 #99 aaaaaaaaaa <x>")
    end
  end
end
