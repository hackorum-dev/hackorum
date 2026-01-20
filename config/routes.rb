Rails.application.routes.draw do
  namespace :admin do
    resources :imap_sync_states, only: [:index]
    resources :topic_merges, only: [:index]
    resources :topics, only: [] do
      resource :merge, controller: 'topic_merges', only: [:new, :create] do
        post :preview
      end
    end
  end
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  get "up" => "rails/health#show", as: :rails_health_check

  if Rails.env.development?
    get "preview/maintenance" => ->(env) {
      PendingMigrationCatcher.new(nil).send(:render_maintenance_page)
    }
  end
  get "messages/by-id/*message_id", to: "messages#by_message_id", as: :message_by_id, format: false

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  root "topics#index"

  # Settings namespace
  namespace :settings do
    root "accounts#show"
    resource :account, only: [:show]
    resource :profile, only: [:show]
    resource :password, only: [:show]
    resource :import, only: [:show, :create]
    resource :deletion, only: [:show, :create]

    resources :teams, only: [:index, :show, :create, :update, :destroy] do
      resources :team_members, only: [:create, :update, :destroy]
    end

    resource :username, only: [:update]
    resource :preferences, only: [:update]
    patch "password/current", to: "passwords#update_current", as: :update_current_password
    resources :emails, only: [:create, :destroy] do
      post :primary, on: :member
    end
  end
  resources :topics, only: [:index, :show] do
    collection do
      get :search
      get :user_state_frame
      post :user_state
      get :new_topics_count
      post :aware_bulk
      post :aware_all
    end
    member do
      post :aware
      post :read_all
      post :star
      delete :unstar
      get :latest_patchset
    end
  end
  resources :activities, only: [:index] do
    post :mark_all_read, on: :collection
  end
  resources :notes, only: [:create, :update, :destroy]
  resources :note_mentions, only: [:destroy]
  get "stats", to: "stats#show", as: :stats
  get "stats/data", to: "stats#data", as: :stats_data

  # Reports
  get "reports", to: "reports#index", as: :reports
  get "reports/weekly/:year/:week", to: "reports#show", defaults: { period_type: "weekly" }, as: :weekly_report
  get "reports/monthly/:year/:month", to: "reports#show", defaults: { period_type: "monthly" }, as: :monthly_report

  # Help pages
  resources :help, only: [:index, :show], param: :slug
  get "person/*email/contributions/:year", to: "people#contributions", as: :person_contributions, format: false
  get "person/*email/activity/:date", to: "people#daily_activity", as: :person_activity, format: false
  get "person/*email/activity/month/:year/:month", to: "people#monthly_activity", as: :person_monthly_activity, format: false
  get "person/*email/activity/week/:year/:week", to: "people#weekly_activity", as: :person_weekly_activity, format: false
  get "person/*email", to: "people#show", as: :person, format: false
  get "people/*email", to: redirect { |params, _req| "/person/#{params[:email]}" }, format: false

  get "team/:name/contributions/:year", to: "teams_profile#contributions", as: :team_contributions
  get "team/:name/activity/:date", to: "teams_profile#daily_activity", as: :team_activity
  get "team/:name/activity/month/:year/:month", to: "teams_profile#monthly_activity", as: :team_monthly_activity
  get "team/:name/activity/week/:year/:week", to: "teams_profile#weekly_activity", as: :team_weekly_activity
  get "team/:name", to: "teams_profile#show", as: :team_profile

  # Authentication
  resource :session, only: [:new, :create, :destroy]
  resource :registration, only: [:new, :create]
  get '/verify', to: 'verifications#show', as: :verification
  resource :password, only: [:new, :create, :edit, :update]

  # OmniAuth callbacks
  get '/auth/:provider/callback', to: 'omniauth_callbacks#google_oauth2'

  post "messages/:id/read", to: "messages#read", as: :read_message
  resources :attachments, only: [:show]

  if defined?(PgHero)
    constraints AdminConstraint.new do
      mount PgHero::Engine, at: "/pghero"
    end
  end

  if Rails.env.development?
    mount LetterOpenerWeb::Engine, at: "/letter_opener"
  end
end
