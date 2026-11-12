require "rails_helper"

RSpec.describe "API v1, the promise not to send", type: :request do
  describe "the watch on jobs" do
    it "is on every spec of the API" do
      groups = RSpec.world.example_groups.select { |group| group.metadata[:file_path].include?("/spec/requests/api/v1/") }

      expect(groups).to include(self.class.parent_groups.last)
      expect(groups.reject { |group| group.metadata[:api_no_send] }).to eq([])
      expect(groups.reject { |group| group.included_modules.include?(ApiNoSend::Watched) }).to eq([])
    end

    it "sees a job that is queued while a request is answered, and counts the requests" do
      expect(ActiveJob::Base.queue_adapter).to be_a(ActiveJob::QueueAdapters::TestAdapter)
      watch = api_job_watch

      PersonIdPropagationJob.perform_later(1, 1, 1)
      expect(watch[:jobs]).to eq([])

      watch[:active] = true
      PersonIdPropagationJob.perform_later(1, 1, 1)
      PersonIdPropagationJob.set(wait: 1.hour).perform_later(1, 1, 1)
      watch[:active] = false
      expect(watch[:jobs].map(&:last)).to eq(%w[PersonIdPropagationJob PersonIdPropagationJob])
      watch[:jobs].clear

      get "/api/v1/mailing_lists"
      expect(watch).to include(requests: 1, active: false, jobs: [])
    end
  end

  it "writes through five routes and no other: a new one has to be added to this list" do
    routes = Rails.application.routes.routes.select { |route| route.path.spec.to_s.match?(%r{\A/api/v1(/|\z|\()}) }
    catch_all, named = routes.partition { |route| route.defaults[:controller] == "api/v1/errors" }
    writes = named.flat_map do |route|
      verbs = route.verb.to_s.split("|")
      (verbs.empty? ? [ "ANY" ] : verbs - [ "GET" ]).map { |verb| [ verb, route.path.spec.to_s.delete_suffix("(.:format)") ] }
    end

    expect(writes).to match_array([
      [ "POST", "/api/v1/drafts" ],
      [ "PATCH", "/api/v1/drafts/:id" ],
      [ "DELETE", "/api/v1/drafts/:id" ],
      [ "POST", "/api/v1/drafts/:id/attachments" ],
      [ "DELETE", "/api/v1/drafts/:id/attachments/:attachment_id" ]
    ])
    expect(catch_all.map { |route| [ route.path.spec.to_s, route.defaults[:action] ] })
      .to eq([ [ "/api/v1(/*unmatched)(.:format)", "not_found" ] ])
    expect(Api::V1::ErrorsController.public_instance_methods(false)).to eq([ :not_found ])
  end

  # What runs is covered by the mocks and the job watch of the "API never sends" context.
  describe "the source, as far as a scan of its text sees: the names written out in the API's files and in " \
           "the app files those name, no call followed further, nothing built at run time or reached through a gem" do
    let(:root) { Rails.root.to_s }
    let(:own) do
      Dir["#{root}/app/{controllers,serializers,services,queries}/api/**/*.rb", "#{root}/app/controllers/concerns/api/**/*.rb",
          "#{root}/app/services/drafts/**/*.rb"]
    end
    let(:sends) { /SendOutgoingMessageJob|Gmail::SendClient|send_raw|MessageBuilder|TokenRefresher|deliver_(now|later)/ }
    let(:callbacks) { /\b(after|before|around)_(commit|save|create|update|destroy|touch|validation|rollback|initialize|find)\b/ }

    # app files that define a constant the given files name, without the site's controllers
    def referenced(files)
      index = Dir["#{root}/app/*/**/*.rb"].group_by { |file| file.sub(%r{\A#{root}/app/[^/]+/(concerns/)?}, "").delete_suffix(".rb") }
      names = files.flat_map { |file| File.read(file).scan(/\b[A-Z][A-Za-z0-9]*(?:::[A-Z][A-Za-z0-9]*)*/) }.uniq
      found = names.flat_map do |name|
        parts = name.split("::")
        (1..parts.size).flat_map { |size| index.fetch(parts.first(size).join("::").underscore, []) }
      end
      found.uniq.reject { |file| file.start_with?("#{root}/app/controllers/") } - files
    end

    def expect_none(files, pattern)
      files.each do |file|
        hits = File.readlines(file).grep(pattern)
        expect(hits).to eq([]), "#{file}: #{hits.first}"
      end
    end

    it "of the API has nothing that sends, queues a job or marks a draft as being sent" do
      forbidden = /#{sends}|send_now|Gmail::|STATUS_SENDING|sending_started_at|status:\s*["']sen|perform_(now|later)|\.enqueue\b/

      expect(own.map { |file| file.delete_prefix("#{root}/app/") }).to include(
        "controllers/api/v1/drafts_controller.rb", "controllers/api/v1/draft_attachments_controller.rb",
        "serializers/api/v1/draft_serializer.rb", "services/drafts/creator.rb", "services/drafts/attachment_adder.rb",
        "services/drafts/token_limits.rb", "queries/api/topic_list.rb", "queries/api/saved_search_list.rb"
      )
      expect_none(own, forbidden)
    end

    it "of what the API names has nothing that sends" do
      files = referenced(own)

      expect(files.map { |file| file.delete_prefix("#{root}/app/") }).to include(
        "models/outgoing_draft.rb", "models/draft_attachment.rb", "models/message.rb", "models/api_token.rb",
        "services/outgoing/recipient_resolver.rb"
      )
      expect_none(files, sends)
    end

    it "of the draft models has no callback and no job: saving a draft does nothing but save it" do
      files = %w[outgoing_draft draft_attachment].map { |name| "#{root}/app/models/#{name}.rb" }

      expect_none(files, /#{callbacks}|perform_(now|later)|deliver_|#{sends}/)
    end
  end
end
