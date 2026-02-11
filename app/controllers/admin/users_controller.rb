# frozen_string_literal: true

class Admin::UsersController < Admin::BaseController
  before_action :set_user, only: [ :toggle_admin, :new_email, :confirm_email, :add_email ]

  def active_admin_section
    :users
  end

  def index
    @users = User.active
                 .includes(person: [ :default_alias, :aliases ])
                 .order(created_at: :desc)
                 .limit(params.fetch(:limit, 50).to_i)
                 .offset(params.fetch(:offset, 0).to_i)
  end

  def toggle_admin
    if @user == current_user
      return redirect_to admin_users_path, alert: "You cannot change your own admin status."
    end

    @user.update!(admin: !@user.admin?)
    redirect_to admin_users_path, notice: "#{@user.username || 'User'} is #{@user.admin? ? 'now' : 'no longer'} an admin."
  end

  def new_email
  end

  def confirm_email
    @email = params[:email].to_s.strip.downcase
    if @email.blank?
      return redirect_to new_email_admin_user_path(@user), alert: "Email address is required."
    end

    @existing_aliases = Alias.by_email(@email)
    @owned_by_other = @existing_aliases.where.not(user_id: [ nil, @user.id ]).exists?
  end

  def add_email
    email = params[:email].to_s.strip.downcase
    if email.blank?
      return redirect_to admin_users_path, alert: "Email address is required."
    end

    person = @user.person || Person.create!
    @user.update!(person_id: person.id) if @user.person_id.nil?

    aliases = Alias.by_email(email)

    if aliases.where.not(user_id: [ nil, @user.id ]).exists?
      return redirect_to admin_users_path, alert: "Email is linked to another account. Cannot associate."
    end

    if aliases.exists?
      aliases.find_each do |al|
        person.attach_alias!(al, user: @user)
        al.update_columns(verified_at: Time.current)
      end

      AdminEmailChange.create!(
        performed_by: current_user,
        target_user: @user,
        email: email,
        aliases_attached: aliases.count,
        created_new_alias: false
      )
    else
      al = Alias.create!(person: person, user: @user, name: email, email: email, verified_at: Time.current)
      person.update!(default_alias_id: al.id) if person.default_alias_id.nil?

      AdminEmailChange.create!(
        performed_by: current_user,
        target_user: @user,
        email: email,
        aliases_attached: 0,
        created_new_alias: true
      )
    end

    redirect_to admin_users_path, notice: "Email #{email} has been associated with #{@user.username || 'the user'}."
  end

  private

  def set_user
    @user = User.find(params[:id])
  end
end
