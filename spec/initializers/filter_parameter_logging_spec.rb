require "rails_helper"

RSpec.describe "Parameters in the log" do
  let(:filter) { ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters) }

  it "has no draft text and no uploaded content" do
    sent = { "reply_to_message_id" => 7, "subject" => "Re: x", "body" => "text", "quote" => "quoted",
             "file_name" => "a.patch", "content_base64" => "YQ==" }

    expect(filter.filter(sent)).to eq(
      "reply_to_message_id" => 7, "subject" => "[FILTERED]", "body" => "[FILTERED]", "quote" => "[FILTERED]",
      "file_name" => "a.patch", "content_base64" => "[FILTERED]"
    )
  end

  it "has no text of a draft or a note written on the site" do
    sent = { "outgoing_draft" => { "subject" => "Re: x", "body" => "text" }, "note" => { "body" => "text", "topic_id" => 3 } }

    expect(filter.filter(sent)).to eq(
      "outgoing_draft" => { "subject" => "[FILTERED]", "body" => "[FILTERED]" },
      "note" => { "body" => "[FILTERED]", "topic_id" => 3 }
    )
  end
end
