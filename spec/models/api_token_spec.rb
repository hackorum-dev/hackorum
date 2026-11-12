require "rails_helper"

RSpec.describe ApiToken do
  let(:user) { create(:user) }

  describe ".issue!" do
    it "returns the record and a prefixed raw value, storing only the digest" do
      token, raw = ApiToken.issue!(user: user, name: "laptop")

      expect(raw).to start_with("hko_")
      expect(token.token_digest).to eq(ApiToken.digest(raw))
      expect(token.attributes.values).not_to include(raw)
    end

    it "needs a name" do
      expect { ApiToken.issue!(user: user, name: "") }.to raise_error(ActiveRecord::RecordInvalid)
    end

    it "refuses control characters in the name" do
      [ "a\0b", "a\r\nb", "a\tb" ].each do |name|
        expect { ApiToken.issue!(user: user, name: name) }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end
  end

  describe ".authenticate" do
    it "finds a live token" do
      token, raw = ApiToken.issue!(user: user, name: "laptop")
      expect(ApiToken.authenticate(raw)).to eq(token)
    end

    it "rejects unknown, blank and unprefixed values" do
      expect(ApiToken.authenticate("hko_nope")).to be_nil
      expect(ApiToken.authenticate("")).to be_nil
      expect(ApiToken.authenticate(nil)).to be_nil
      expect(ApiToken.authenticate("nope")).to be_nil
      expect(ApiToken.authenticate([ "hko_x" ])).to be_nil
    end

    it "rejects a revoked token" do
      token, raw = ApiToken.issue!(user: user, name: "laptop")
      token.revoke!
      expect(ApiToken.authenticate(raw)).to be_nil
    end

    it "rejects an expired token" do
      _, raw = ApiToken.issue!(user: user, name: "laptop", expires_at: 1.minute.ago)
      expect(ApiToken.authenticate(raw)).to be_nil
    end

    it "accepts a token that expires later" do
      token, raw = ApiToken.issue!(user: user, name: "laptop", expires_at: 1.day.from_now)
      expect(ApiToken.authenticate(raw)).to eq(token)
    end

    it "rejects tokens of deleted and unverified users" do
      _, raw = ApiToken.issue!(user: user, name: "laptop")

      user.update_columns(deleted_at: Time.current)
      expect(ApiToken.authenticate(raw)).to be_nil

      user.update_columns(deleted_at: nil, verified_at: nil)
      expect(ApiToken.authenticate(raw)).to be_nil
    end
  end

  describe "#touch_last_used!" do
    it "writes once per minute" do
      token, = ApiToken.issue!(user: user, name: "laptop")

      freeze_time do
        token.touch_last_used!
        first = token.reload.last_used_at
        expect(first).to eq(Time.current)

        travel 30.seconds
        token.touch_last_used!
        expect(token.reload.last_used_at).to eq(first)

        travel 31.seconds
        token.touch_last_used!
        expect(token.reload.last_used_at).to eq(Time.current)
      end
    end
  end
end
