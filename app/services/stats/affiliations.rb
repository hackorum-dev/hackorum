module Stats
  # Company per person per date, loaded once for a set of people so the tabs
  # never query per credit.
  class Affiliations
    UNKNOWN = "Individual / unknown".freeze

    def self.label(company) = company.presence || UNKNOWN

    def initialize(person_ids)
      @rows = PersonAffiliation.where(person_id: person_ids.compact.uniq)
                               .order(Arel.sql("since DESC NULLS LAST, CASE source WHEN 'manual' THEN 0 WHEN 'contributors_page' THEN 1 ELSE 2 END, id DESC"))
                               .group_by(&:person_id)
    end

    def company_for(person_id, time)
      return nil if person_id.nil?

      date = time.to_date
      row = (@rows[person_id] || []).find do |a|
        (a.since.nil? || a.since <= date) && (a.until.nil? || a.until >= date)
      end
      row&.company
    end
  end
end
