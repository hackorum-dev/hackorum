class PeopleController < ApplicationController
  include ProfileActivity

  before_action :load_person

  def show
    @first_message_at = Message.where(sender_person_id: @person.id).minimum(:created_at)
    @last_message_at = Message.where(sender_person_id: @person.id).maximum(:created_at)
    @profile_email = profile_email
    load_activity_data
  end

  def contributions
    @profile_email = profile_email
    load_activity_data
    render :activity
  end

  def daily_activity
    date = parse_activity_date
    @profile_email = profile_email
    @activity_period = { type: :day, date: date }
    load_activity_data(scope: messages_scope_for_date(date), year: date.year)
    render :activity
  end

  def monthly_activity
    year = params[:year].to_i
    month = params[:month].to_i
    start_date = Date.new(year, month, 1)
    end_date = start_date.end_of_month
    @profile_email = profile_email
    @activity_period = { type: :month, year: year, month: month }
    load_activity_data(scope: messages_scope_for_range(start_date, end_date), year: year)
    render :activity
  end

  def weekly_activity
    year = params[:year].to_i
    week = params[:week].to_i
    wday_start = WeekCalculation.parse_week_start(params[:week_start])
    start_date = WeekCalculation.week_start_date(year, week, wday_start)
    end_date = start_date + 6
    @profile_email = profile_email
    @activity_period = { type: :week, year: year, week: week, start_date: start_date, end_date: end_date }
    load_activity_data(scope: messages_scope_for_range(start_date, end_date), year: year)
    render :activity
  end

  private

  def activity_person_ids
    @person.id
  end

  def load_person
    @person = find_person
    @primary_alias = @person.default_alias
    @aliases = @person.aliases.with_sent_messages.order(:email)
    @teams = load_visible_teams
  end

  def load_visible_teams
    user = @person.user
    return [] unless user

    all_teams = user.teams.includes(:team_members)

    all_teams.select do |team|
      if team.visibility_open? || team.visibility_visible?
        true
      elsif current_user && current_user.id == user.id
        true
      elsif current_user && team.member?(current_user)
        true
      else
        false
      end
    end
  end

  def find_person
    email_param = params[:email].to_s
    person = Person.find_by_email(email_param)
    return Person.includes(:aliases, :default_alias).find(person.id) if person

    if email_param.match?(/\A\d+\z/)
      return Person.includes(:aliases, :default_alias).find(email_param)
    end

    raise ActiveRecord::RecordNotFound
  end

  def profile_email
    @primary_alias&.email || @aliases.first&.email || params[:email].to_s
  end
end
