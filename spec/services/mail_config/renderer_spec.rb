require "rails_helper"

RSpec.describe MailConfig::Renderer do
  let(:dir) { Dir.mktmpdir }
  after { FileUtils.remove_entry(dir) }

  def fragment(name, content) = File.write(File.join(dir, name), content)
  def read(name) = File.read(File.join(dir, name))
  def render = described_class.call(dir: dir, domain: "hackorum.test")

  before do
    fragment("postfix-accounts.system.cf", "receiver@hackorum.test|{SHA512-CRYPT}$6$r\napp@hackorum.test|{SHA512-CRYPT}$6$a")
    fragment("postfix-virtual.system.cf", "dmarc@hackorum.test ops@example.com\n")
  end

  it "renders the four files" do
    zed = grant_mailbox(login: "zed")
    dutow = grant_mailbox(login: "dutow", quota_mb: 2048)
    dutow.add_alias("zsolt.parragi")
    dutow.add_alias("info")

    expect(render).to match_array(%w[postfix-accounts.cf postfix-virtual.cf dovecot-quotas.cf sender-login.map])
    expect(read("postfix-accounts.cf")).to eq(<<~EOS)
      receiver@hackorum.test|{SHA512-CRYPT}$6$r
      app@hackorum.test|{SHA512-CRYPT}$6$a
      zed@hackorum.test|#{zed.password_hash}
      dutow@hackorum.test|#{dutow.password_hash}
    EOS
    expect(read("postfix-virtual.cf")).to eq(<<~EOS)
      dmarc@hackorum.test ops@example.com
      info@hackorum.test dutow@hackorum.test
      zsolt.parragi@hackorum.test dutow@hackorum.test
    EOS
    expect(read("dovecot-quotas.cf")).to eq("zed@hackorum.test:5120M\ndutow@hackorum.test:2048M\n")
    expect(read("sender-login.map")).to eq(<<~EOS)
      receiver@hackorum.test receiver@hackorum.test
      app@hackorum.test app@hackorum.test
      zed@hackorum.test zed@hackorum.test
      dutow@hackorum.test dutow@hackorum.test
      info@hackorum.test dutow@hackorum.test
      zsolt.parragi@hackorum.test dutow@hackorum.test
    EOS
    expect(File.stat(File.join(dir, "postfix-accounts.cf")).mode & 0o777).to eq(0o640)
    expect(File.stat(File.join(dir, "postfix-virtual.cf")).mode & 0o777).to eq(0o644)
  end

  # the mailserver looks accounts and quotas up with an unanchored grep and takes the first hit
  it "puts a login before every other login its pattern can match" do
    %w[brian ian a-b a.b xa.b].each { |l| grant_mailbox(login: l) }
    render
    order = %w[a.b a-b ian xa.b brian]
    expect(read("postfix-accounts.cf").lines.drop(2).map { |l| l.split("@").first }).to eq(order)
    expect(read("dovecot-quotas.cf").lines.map { |l| l.split("@").first }).to eq(order)
    order.each do |login|
      first_hit = read("postfix-accounts.cf").lines.drop(2).find { |l| l.match?(/#{login}@hackorum.test/) }
      expect(first_hit).to start_with("#{login}@"), login
      expect(read("dovecot-quotas.cf").lines.find { |l| l.match?(/#{login}@hackorum.test:/i) }).to start_with("#{login}@"), login
    end
  end

  it "does not render a mailbox whose login an unanchored match would mix up with a system account" do
    fragment("postfix-accounts.system.cf", "receiver@hackorum.test|x\nlistrx@hackorum.test|y\n")
    grant_mailbox(login: "rx")
    grant_mailbox(login: "mylistrx")
    grant_mailbox(login: "zed")
    expect(Rails.logger).to receive(:error).with(/rx@hackorum.test/).ordered
    expect(Rails.logger).to receive(:error).with(/mylistrx@hackorum.test/).ordered
    render
    expect(read("postfix-accounts.cf").lines.map { |l| l.split("@").first }).to eq(%w[receiver listrx zed])
    expect(read("dovecot-quotas.cf")).to eq("zed@hackorum.test:5120M\n")
    expect(read("sender-login.map")).not_to match(/^(my)?(list)?rx@.* (rx|mylistrx)@/)
  end

  it "renders only the system part without mailboxes" do
    render
    expect(read("postfix-accounts.cf").lines.size).to eq(2)
    expect(read("dovecot-quotas.cf")).to eq("")
  end

  it "skips disabled mailboxes and deleted users" do
    grant_mailbox(login: "off").disable!
    grant_mailbox(login: "gone").user.update_columns(deleted_at: Time.current)
    render
    expect(read("postfix-accounts.cf")).not_to include("off@", "gone@")
    expect(read("sender-login.map")).not_to include("off@", "gone@")
  end

  it "renders only admin mailboxes on staging" do
    grant_mailbox(login: "plain")
    grant_mailbox(user: create(:user, username: "boss", admin: true))
    allow(Hackorum).to receive(:staging?).and_return(true)
    render
    expect(read("postfix-accounts.cf")).to include("boss@")
    expect(read("postfix-accounts.cf")).not_to include("plain@")
  end

  it "does not rewrite unchanged files" do
    grant_mailbox(login: "dutow")
    render
    before = File.stat(File.join(dir, "postfix-accounts.cf")).ino
    expect(render).to eq([])
    expect(File.stat(File.join(dir, "postfix-accounts.cf")).ino).to eq(before)
  end

  it "refuses to write without the accounts fragment" do
    grant_mailbox(login: "dutow")
    render
    [ -> { File.delete(File.join(dir, "postfix-accounts.system.cf")) },
      -> { fragment("postfix-accounts.system.cf", "\n# nothing\n") },
      -> { File.delete(File.join(dir, "postfix-virtual.system.cf")) } ].each do |breakage|
      fragment("postfix-accounts.system.cf", "receiver@hackorum.test|x\n")
      fragment("postfix-virtual.system.cf", "")
      breakage.call
      grant_mailbox
      before = read("postfix-accounts.cf")
      expect { render }.to raise_error(MailConfig::Renderer::MissingFragment)
      expect(read("postfix-accounts.cf")).to eq(before)
    end
  end

  it "leaves no temp files behind" do
    render
    expect(Dir.children(dir).sort).to eq(%w[dovecot-quotas.cf postfix-accounts.cf postfix-accounts.system.cf postfix-virtual.cf postfix-virtual.system.cf sender-login.map])
  end

  it "leaves the old file and no temp file when the rename fails" do
    grant_mailbox(login: "dutow")
    render
    before = read("postfix-accounts.cf")
    grant_mailbox(login: "zed")
    allow(File).to receive(:rename).and_raise(Errno::EIO)
    expect { render }.to raise_error(Errno::EIO)
    expect(read("postfix-accounts.cf")).to eq(before)
    expect(Dir.children(dir).grep(/\.tmp\z/)).to be_empty
  end

  it "ignores a stale temp file from a killed process" do
    stale = File.join(dir, ".postfix-accounts.cf.#{Process.pid}.tmp")
    File.write(stale, "junk")
    File.chmod(0o600, stale)
    mailbox = grant_mailbox(login: "dutow")
    render
    expect(read("postfix-accounts.cf")).to include("dutow@hackorum.test|#{mailbox.password_hash}")
    expect(File.stat(File.join(dir, "postfix-accounts.cf")).mode & 0o777).to eq(0o640)
    expect(Dir.children(dir).grep(/\.tmp\z/)).to be_empty
  end

  it "creates temp files with the target mode" do
    modes = []
    allow(File).to receive(:open).and_wrap_original do |orig, *args, &blk|
      modes << args.last if args[0].to_s.end_with?(".tmp")
      orig.call(*args, &blk)
    end
    render
    expect(modes).to include(0o640, 0o644)
  end

  it "does not render an alias equal to a system key" do
    fragment("postfix-virtual.system.cf", "dmarc@hackorum.test ops@example.com\nteam@hackorum.test ops@example.com\n")
    fragment("postfix-accounts.system.cf", "receiver@hackorum.test|x\nops@hackorum.test|y\n")
    mailbox = grant_mailbox(login: "dutow")
    mailbox.add_alias("team")
    mailbox.add_alias("ops")
    mailbox.add_alias("fine")
    allow(Rails.logger).to receive(:error)
    render
    expect(read("postfix-virtual.cf").scan(/^team@hackorum.test /).size).to eq(1)
    expect(read("postfix-virtual.cf")).to include("team@hackorum.test ops@example.com\n", "fine@hackorum.test dutow@hackorum.test")
    expect(read("postfix-virtual.cf")).not_to include("team@hackorum.test dutow@hackorum.test", "ops@hackorum.test dutow@hackorum.test")
    expect(read("sender-login.map")).not_to include("team@hackorum.test dutow", "ops@hackorum.test dutow@")
    expect(read("sender-login.map")).to include("ops@hackorum.test ops@hackorum.test\n", "fine@hackorum.test dutow@hackorum.test")
    expect(read("postfix-accounts.cf").scan("ops@hackorum.test|").size).to eq(1)
    expect(Rails.logger).to have_received(:error).with(/team@hackorum.test/)
    expect(Rails.logger).to have_received(:error).with(/ops@hackorum.test/)
  end

  it "leaves out a mailbox whose login equals a system key" do
    fragment("postfix-accounts.system.cf", "receiver@hackorum.test|x\nops@hackorum.test|y\n")
    mailbox = grant_mailbox(login: "ops")
    mailbox.add_alias("other")
    allow(Rails.logger).to receive(:error)
    render
    expect(read("postfix-accounts.cf").scan("ops@hackorum.test|").size).to eq(1)
    expect(read("postfix-accounts.cf")).not_to include(mailbox.password_hash)
    expect(read("dovecot-quotas.cf")).to eq("")
    expect(read("postfix-virtual.cf")).not_to include("other@")
    expect(read("sender-login.map")).not_to include("other@")
    expect(read("sender-login.map").scan("ops@hackorum.test ops@hackorum.test").size).to eq(1)
    expect(Rails.logger).to have_received(:error).with(/ops@hackorum.test/)
  end

  it "is a no-op without a config dir" do
    expect(described_class.call(dir: nil, domain: "hackorum.test")).to eq(:skipped)
  end

  it "fails without a domain" do
    expect { described_class.call(dir: dir, domain: nil) }.to raise_error(ArgumentError)
  end
end
