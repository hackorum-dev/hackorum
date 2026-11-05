require "rails_helper"

RSpec.describe StagingMailRouter do
  subject(:router) do
    described_class.new(allowlist: allowlist, sink_host: "mailpit", sink_port: 1025)
  end

  let(:allowlist) { [ "zsolt@example.com", "@hackorum.dev" ] }

  def build(to:, cc: nil, bcc: nil)
    Mail.new do
      from "noreply@hackorum.dev"
      subject "hi"
      body "x"
    end.tap do |m|
      m.to = to
      m.cc = cc if cc
      m.bcc = bcc if bcc
      m.delivery_method :smtp, address: "mailserver", port: 587
    end
  end

  it "leaves mail alone when every recipient is allowlisted" do
    mail = build(to: "Zsolt <ZSOLT@example.com>", cc: "kai@hackorum.dev")
    router.delivering_email(mail)
    expect(mail.delivery_method.settings[:address]).to eq("mailserver")
    expect(mail["X-Hackorum-Staging-Routed"]).to be_nil
  end

  it "routes to the sink when any recipient is not allowlisted" do
    mail = build(to: "zsolt@example.com", bcc: "someone@gmail.com")
    router.delivering_email(mail)
    settings = mail.delivery_method.settings
    expect(settings[:address]).to eq("mailpit")
    expect(settings[:port]).to eq(1025)
    expect(settings[:enable_starttls_auto]).to be(false)
    expect(settings[:user_name]).to be_nil
    expect(mail.to).to eq([ "zsolt@example.com" ])
    expect(mail.bcc).to eq([ "someone@gmail.com" ])
    expect(mail["X-Hackorum-Staging-Routed"].value).to eq("sink")
  end

  it "does not match subdomains or suffixes on @domain patterns" do
    mail = build(to: "a@sub.hackorum.dev")
    router.delivering_email(mail)
    expect(mail.delivery_method.settings[:address]).to eq("mailpit")

    mail = build(to: "a@nothackorum.dev")
    router.delivering_email(mail)
    expect(mail.delivery_method.settings[:address]).to eq("mailpit")
  end

  it "routes everything to the sink when the allowlist is empty" do
    empty = described_class.new(allowlist: [], sink_host: "mailpit", sink_port: 1025)
    mail = build(to: "zsolt@example.com")
    empty.delivering_email(mail)
    expect(mail.delivery_method.settings[:address]).to eq("mailpit")
  end

  it "routes to the sink when cc is not allowlisted" do
    mail = build(to: "zsolt@example.com", cc: "someone@gmail.com")
    router.delivering_email(mail)
    expect(mail.delivery_method.settings[:address]).to eq("mailpit")
  end

  it "routes to the sink when bcc is not allowlisted" do
    mail = build(to: "zsolt@example.com", bcc: "someone@gmail.com")
    router.delivering_email(mail)
    expect(mail.delivery_method.settings[:address]).to eq("mailpit")
  end

  it "routes recipient-less mail to the sink" do
    mail = build(to: nil)
    router.delivering_email(mail)
    expect(mail.delivery_method.settings[:address]).to eq("mailpit")
  end

  it "logs the decision" do
    mail = build(to: "x@gmail.com")
    expect(Rails.logger).to receive(:info).with(a_string_matching(/staging_mail.*sink.*x@gmail.com/))
    router.delivering_email(mail)
  end

  describe ".from_env" do
    it "parses the comma separated allowlist and sink settings" do
      r = described_class.from_env(
        "STAGING_MAIL_ALLOWLIST" => " a@b.c, @d.e ,,",
        "STAGING_MAIL_SINK_HOST" => "sink",
        "STAGING_MAIL_SINK_PORT" => "2525"
      )
      expect(r.allowlist).to eq([ "a@b.c", "@d.e" ])
      expect(r.sink_host).to eq("sink")
      expect(r.sink_port).to eq(2525)
    end

    it "defaults the sink to mailpit:1025 and the allowlist to empty" do
      r = described_class.from_env({})
      expect(r.allowlist).to eq([])
      expect(r.sink_host).to eq("mailpit")
      expect(r.sink_port).to eq(1025)
    end
  end
end
