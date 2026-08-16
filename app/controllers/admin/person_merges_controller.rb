# frozen_string_literal: true

class Admin::PersonMergesController < Admin::BaseController
  CANDIDATE_LIMIT = 20

  before_action :set_source_person, only: [ :new, :preview, :create ]
  before_action :set_target_person, only: [ :preview, :create ]

  def active_admin_section
    :person_merges
  end

  def index
    @person_merges = PersonMerge.includes(:performed_by).order(created_at: :desc).limit(100)
  end

  def new
    @target_query = params[:target_q].to_s.strip
    @candidates = if @target_query.present?
      Person.matching(@target_query)
            .where.not(id: @source_person.id)
            .includes(:aliases, :default_alias, :user)
            .limit(CANDIDATE_LIMIT)
    else
      Person.none
    end
  end

  def preview
    return redirect_to_new_with_error("Target person is required") unless @target_person

    error = service.validation_error
    return redirect_to_new_with_error(error) if error

    @preview = service.preview
  end

  def create
    return redirect_to_new_with_error("Target person is required") unless @target_person

    result = service.call

    if result.success?
      redirect_to admin_people_path,
                  notice: "Merged #{result.person_merge.source_name} into #{result.person_merge.target_name}."
    else
      redirect_to_new_with_error(result.error)
    end
  end

  private

  def service
    @service ||= PersonMergeService.new(
      source_person: @source_person,
      target_person: @target_person,
      merged_by: current_user
    )
  end

  def set_source_person
    @source_person = Person.find(params[:person_id])
  rescue ActiveRecord::RecordNotFound
    redirect_to admin_people_path, alert: "Source person not found"
  end

  def set_target_person
    target_id = params[:target_person_id].presence
    @target_person = Person.find_by(id: target_id) if target_id
  end

  def redirect_to_new_with_error(message)
    redirect_to new_admin_person_merge_path(@source_person), alert: message
  end
end
