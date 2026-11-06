module Stats
  # One major version as a statistics subject: branch names, the tags that
  # bound its cycle, and whether it is finished. Reads release_tags only.
  class Release
    FIRST_MAJOR = 10
    # affiliation data is only curated from this cycle on
    COMPANIES_FROM_MAJOR = 19
    # LLM numbers are shown when this share of the commits with a thread has
    # a verdict; a partial run would skew every lineage and review tile
    LLM_MIN_COVERAGE = 0.8

    attr_reader :major

    def self.find(major)
      major = major.to_i
      available.find { |release| release.major == major }
    end

    # every major with a branch (a beta1 tag), newest first, plus the next
    # major while master already has commits past the newest branch
    def self.available
      majors = ReleaseTag.where("name ~ ?", '^REL_\d+_BETA1$')
                         .pluck(:name).map { |n| n[/\d+/].to_i }
                         .select { |m| m >= FIRST_MAJOR }.sort.reverse
      return [] if majors.empty?

      newest = majors.first
      dev = Commit.where("'master' = ANY(branches) AND NOT (? = ANY(branches))", "REL_#{newest}_STABLE")
      list = majors.map { |m| new(m) }.select { |r| r.start.present? }
      dev.exists? ? [ new(newest + 1) ] + list : list
    end

    def initialize(major)
      @major = major.to_i
    end

    def label = "PG#{major}"

    def in_development? = beta1_tag.nil?

    def branch = in_development? ? "master" : "REL_#{major}_STABLE"

    def previous_branch = "REL_#{major - 1}_STABLE"

    def closed? = ga_tag.present?

    def companies? = major >= COMPANIES_FROM_MAJOR

    def llm? = scopes.llm?

    def start = tag_time("REL_#{major - 1}_BETA1")

    def previous_ga = tag_time("REL_#{major - 1}_0")

    def branch_point = tag_time("REL_#{major}_BETA1")

    def end_at = tag_time("REL_#{major}_0") || Time.current

    def ga_at = tag_time("REL_#{major}_0")

    def scopes = @scopes ||= Scopes.new(self)

    private

    def beta1_tag = tag_time("REL_#{major}_BETA1")

    def ga_tag = tag_time("REL_#{major}_0")

    def tag_time(name)
      @tags ||= {}
      return @tags[name] if @tags.key?(name)

      @tags[name] = ReleaseTag.where(name: name).pick(:released_at)
    end
  end
end
