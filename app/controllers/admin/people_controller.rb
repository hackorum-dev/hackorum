# frozen_string_literal: true

class Admin::PeopleController < Admin::BaseController
  PER_PAGE = 50
  REGISTERED_FILTERS = %w[all registered unregistered].freeze

  def active_admin_section
    :people
  end

  def index
    @query = params[:q].to_s.strip
    @registered = REGISTERED_FILTERS.include?(params[:registered]) ? params[:registered] : "all"
    @senders_only = params[:senders].present?

    scope = filtered_scope
    @people_total_count = scope.count
    @people = scope.left_joins(:default_alias)
                   .includes(:aliases, :default_alias, :user, :contributor_memberships)
                   .order(Arel.sql("aliases.name ASC NULLS LAST"))
                   .page(params[:page]).per(PER_PAGE)
  end

  private

  def filtered_scope
    scope = Person.all
    scope = scope.matching(@query) if @query.present?
    scope = scope.registered if @registered == "registered"
    scope = scope.unregistered if @registered == "unregistered"
    scope = scope.with_senders if @senders_only
    scope
  end
end
