require "csv"

module Stats
  class PeriodsController < BaseController
    before_action :load_period

    def overview
      @data = Stats::Cache.fetch(@period, :overview) { Stats::Period::Overview.new(@period).to_h }
    end

    def pulse
      @pulse_params = Stats::PulseParams.new(params: params)
      data = Stats::Cache.fetch(@period, :pulse, gran: @pulse_params.gran) { Stats::Period::Pulse.new(@period, gran: @pulse_params.gran).to_h }
      @data = data.merge(strips: data[:strips].select { |s| @pulse_params.keys.include?(s[:key]) })
    end

    def people
      @params = Stats::PeopleParams.new(params: params)
      data = Stats::Cache.fetch(@period, :people) { Stats::Period::People.new(@period).to_h }
      @totals = data[:totals]
      @rows = @params.order_rows(data[:rows])
      respond_to do |format|
        format.html do
          @top = @params.top_rows(data[:rows])
          @unlinked = CommitPerson.parsed.where(commit_id: @period.scopes.commit_ids, role: %w[author co_author reviewer], person_id: nil).count
        end
        format.csv { send_data people_csv(@rows), filename: "#{@period.slug}-people.csv", type: "text/csv" }
      end
    end

    def companies
      return render_404 unless @period.companies?

      @data = Stats::Cache.fetch(@period, :companies) { Stats::Period::Companies.new(@period).to_h }
      respond_to do |format|
        format.html
        format.csv { send_data companies_csv(@data[:rows]), filename: "#{@period.slug}-companies.csv", type: "text/csv" }
      end
    end

    def committers
      @data = Stats::Cache.fetch(@period, :committers) { Stats::Period::Committers.new(@period).to_h }
      respond_to do |format|
        format.html
        format.csv { send_data committers_csv(@data[:rows], llm: @data[:llm]), filename: "#{@period.slug}-committers.csv", type: "text/csv" }
      end
    end

    def person
      person = find_stats_person
      overview = Stats::Cache.fetch(@period, :overview) { Stats::Period::Overview.new(@period).to_h }
      @data = Stats::Cache.fetch(@period, :person, id: person.id) { Stats::Period::Person.new(@period, person, overview: overview).to_h }
      @neighbours = @period.neighbours(@periods)
    end

    private

    def find_stats_person
      email = params[:email].to_s
      person = ::Person.find_by_email(email) || (email.match?(/\A\d+\z/) && ::Person.find_by(id: email))
      person or raise ActiveRecord::RecordNotFound
    end

    def companies_csv(rows)
      CSV.generate do |csv|
        csv << %w[rank company people credits authored reviewed committed lines]
        rows.each_with_index do |r, i|
          csv << csv_safe([ i + 1, r[:company], r[:people].size, r[:authored] + r[:reviewed], r[:authored], r[:reviewed], r[:committed], r[:lines] ])
        end
      end
    end

    def committers_csv(rows, llm:)
      keys = %i[commits own for_others authors reverts lines reviewed_for_others judged as_posted alone messages threads people backported]
      keys -= %i[judged as_posted alone] unless llm
      CSV.generate do |csv|
        csv << [ "committer", *keys ]
        rows.each { |r| csv << csv_safe([ r[:name], *r.values_at(*keys) ]) }
      end
    end

    def people_csv(rows)
      company = @period.companies?
      CSV.generate do |csv|
        csv << [ "rank", "name", ("company" if company), "credits", "authored", "reviewed", "committed", "messages", "threads", "committer" ].compact
        rows.each_with_index do |r, i|
          csv << csv_safe([ i + 1, r[:name], (Stats::Affiliations.label(r[:company]) if company), r[:authored] + r[:reviewed],
                            r[:authored], r[:reviewed], r[:committed], r[:messages], r[:threads], r[:committer] ].compact)
        end
      end
    end

    # defuse spreadsheet formulas in user-supplied cells
    def csv_safe(cells)
      cells.map { |v| v.is_a?(String) && v.start_with?("=", "+", "-", "@") ? "'#{v}" : v }
    end

    def load_period
      klass = Stats::Period.kind_class(params[:kind]) or return render_404
      @periods = klass.available
      @period = @periods.find { |p| p.key == params[:key] }
      render_404 unless @period
    end
  end
end
