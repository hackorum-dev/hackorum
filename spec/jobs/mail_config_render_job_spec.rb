require "rails_helper"

RSpec.describe MailConfigRenderJob do
  it "calls the renderer" do
    expect(MailConfig::Renderer).to receive(:call).with(no_args)
    described_class.perform_now
  end

  it "is enqueued by mailbox and address changes" do
    mailbox = nil
    expect { mailbox = grant_mailbox }.to have_enqueued_job(described_class).at_least(:once)
    expect { mailbox.add_alias("extra") }.to have_enqueued_job(described_class).at_least(:once)
    expect { mailbox.change_password("a long mail password") }.to have_enqueued_job(described_class).at_least(:once)
    expect { mailbox.disable! }.to have_enqueued_job(described_class).at_least(:once)
    expect { mailbox.destroy! }.to have_enqueued_job(described_class).at_least(:once)
  end
end
