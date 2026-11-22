require "rails_helper"

RSpec.describe "GET /metrics" do
  it "is not routed when metrics are disabled" do
    skip "metrics enabled in this run" if Hackorum::Metrics.enabled?
    get "/metrics"
    expect(response).to have_http_status(:not_found)
  end

  it "loads no yabeda collectors when metrics are disabled" do
    skip "metrics enabled in this run" if Hackorum::Metrics.enabled?
    expect(defined?(Yabeda::Rails)).to be_nil
    expect(defined?(Yabeda::Prometheus)).to be_nil
  end
end

RSpec.describe "GET /metrics with METRICS_ENABLED=1" do
  it "exposes rails, puma and solid queue series" do
    skip "run with METRICS_ENABLED=1 to exercise the exporter" unless Hackorum::Metrics.enabled?
    get "/up"
    get "/metrics"
    expect(response).to have_http_status(:ok)
    expect(response.content_type).to start_with("text/plain")
    expect(response.body).to include("rails_requests_total")
    expect(response.body).to include("hackorum_solid_queue_ready_jobs")
  end

  it "exposes the latest imap sync state update, 0 without one" do
    skip "run with METRICS_ENABLED=1 to exercise the exporter" unless Hackorum::Metrics.enabled?
    get "/metrics"
    expect(response.body).to match(/^hackorum_imap_last_ingest_timestamp_seconds 0(\.0)?$/)

    ImapSyncState.create!(mailbox_label: "INBOX").update_column(:updated_at, Time.zone.at(1_700_000_000))
    ImapSyncState.create!(mailbox_label: "other").update_column(:updated_at, Time.zone.at(1_600_000_000))
    get "/metrics"
    expect(response.body).to match(/^hackorum_imap_last_ingest_timestamp_seconds 1700000000(\.0)?$/)
  end
end
