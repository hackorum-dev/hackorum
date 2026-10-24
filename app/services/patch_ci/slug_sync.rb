require "digest"
require "json"

module PatchCi
  # Keeps ghcr postgres-patch:<slug> tags pointed at :t<topic_id>. The retag
  # itself runs on GitHub, from a root commit on Config::SLUG_SYNC_BRANCH
  # carrying the whole slug list. Pushed when the list changes and at least
  # every SLUG_RESYNC_HOURS, so a build that landed after the last sync still
  # gets picked up.
  class SlugSync
    STUB_NAME = "hackorum-slugs.yml"
    REUSABLE = "hackorum-dev/postgres-ci/.github/workflows/slug-tags.yml@main"
    STUB = <<~YAML.freeze
      name: hackorum slug tags
      on: push
      concurrency:
        group: hackorum-slug-tags
        cancel-in-progress: true
      jobs:
        retag:
          uses: #{REUSABLE}
          permissions:
            contents: read
            packages: write
    YAML

    Result = Struct.new(:pushed, :error, keyword_init: true)

    def initialize(repo:, remote: "origin", now: -> { Time.current })
      @repo = repo
      @remote = remote
      @now = now
    end

    def call
      state = PatchCiRepoState.current
      return Result.new(pushed: false) unless state

      json = slugs_json
      digest = Digest::SHA256.hexdigest(json)
      return Result.new(pushed: false) unless due?(state, digest, json)

      at = @now.call
      sha = build_commit(json, at)
      result = @repo.run("push", "--force", @remote, "#{sha}:refs/heads/#{Config::SLUG_SYNC_BRANCH}")
      unless result.success?
        return Result.new(pushed: false, error: "push failed: #{result.output.slice(0, 500)}")
      end

      state.update!(slug_sync_digest: digest, slug_sync_pushed_at: at)
      Result.new(pushed: true)
    rescue PatchBranches::GitRepo::Error => e
      Result.new(pushed: false, error: e.message)
    end

    def slugs_json
      rows = Topic.active.where.not(slug: nil).order(:slug).pluck(:slug, :id)
      JSON.pretty_generate(rows.map { |slug, id| { slug: slug, topic_id: id } }) + "\n"
    end

    private

    def due?(state, digest, json)
      if state.slug_sync_pushed_at.nil?
        json != "[]\n"
      else
        state.slug_sync_digest != digest ||
          state.slug_sync_pushed_at <= @now.call - Config::SLUG_RESYNC_HOURS.hours
      end
    end

    # plumbing only: the shared worktree belongs to the patch pushes
    def build_commit(json, at)
      stub = hash_blob(STUB)
      data = hash_blob(json)
      workflows = mktree("100644 blob #{stub}\t#{STUB_NAME}\n")
      github = mktree("040000 tree #{workflows}\tworkflows\n")
      root = mktree("040000 tree #{github}\t.github\n100644 blob #{data}\tslugs.json\n")
      date = at.utc.iso8601
      @repo.run!(*CiCommitBuilder::IDENTITY, "commit-tree", root, "-m", "hackorum slug sync",
                 env: { "GIT_AUTHOR_DATE" => date, "GIT_COMMITTER_DATE" => date }).stdout.strip
    end

    def hash_blob(content)
      @repo.run!("hash-object", "-w", "--stdin", stdin: content).stdout.strip
    end

    def mktree(entries)
      @repo.run!("mktree", stdin: entries).stdout.strip
    end
  end
end
