Rails.application.routes.draw do
  namespace :admin do
    root "dashboard#show"
    resources :users, only: [ :index ] do
      member do
        post :toggle_admin
        get :new_email
        post :confirm_email
        post :add_email
      end
      resources :features, only: [ :index, :create, :destroy ],
        controller: "user_features", param: :name
    end
    resources :people, only: [ :index ] do
      resource :merge, controller: "person_merges", only: [ :new, :create ] do
        post :preview
      end
    end
    resources :person_merges, only: [ :index ]
    resources :email_changes, only: [ :index ]
    resources :imap_sync_states, only: [ :index ]
    resources :topic_merges, only: [ :index ]
    resources :topics, only: [] do
      resource :merge, controller: "topic_merges", only: [ :new, :create ] do
        post :preview
      end
    end
    resources :page_load_stats, only: [ :index ]
    resources :outgoing_messages, only: [ :index ]
    resources :mailing_lists, only: [ :index, :new, :create, :edit, :update ]
    resources :saved_searches
    resources :features, only: [ :index, :show ], param: :name do
      resources :enrollments, only: [ :create, :destroy ], param: :user_id, controller: "feature_enrollments"
    end
    mount PgHero::Engine, at: "/pghero" if defined?(PgHero)
  end
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  get "up" => "rails/health#show", as: :rails_health_check

  if Rails.env.development?
    get "preview/maintenance" => ->(env) {
      PendingMigrationCatcher.new(nil).send(:render_maintenance_page)
    }
  end
  get "messages/by-id/*message_id", to: "messages#by_message_id", as: :message_by_id,
      constraints: { format: /html|json/ }, defaults: { format: "html" }

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  root "topics#index"

  # Settings namespace
  namespace :settings do
    root "accounts#show"
    resource :account, only: [ :show ]
    resource :profile, only: [ :show ]
    resource :password, only: [ :show ]
    resource :import, only: [ :show, :create ]
    resource :deletion, only: [ :show, :create ]
    resources :saved_searches
    resources :saved_search_preferences, only: [ :create ]

    resources :teams, only: [ :index, :show, :create, :update, :destroy ] do
      resources :team_members, only: [ :create, :update, :destroy ]
      resources :saved_searches, module: :teams
    end

    resource :username, only: [ :update ]
    resource :preferences, only: [ :update ]
    patch "password/current", to: "passwords#update_current", as: :update_current_password
    resources :emails, only: [ :create, :destroy ] do
      post :primary, on: :member
    end
    delete "send_auth/:identity_id", to: "send_auth#destroy", as: :send_auth
  end
  resources :topics, only: [ :index, :show ] do
    collection do
      get :search
      get :new_topics_count
      get :row_states
    end
    member do
      post :aware
      post :read_all
      post :unread_all
      post :star
      delete :unstar
      post :ignore
      delete :unignore
      get :latest_patchset
      get :message_batch
      get :attachments_sidebar
      get :patchsets_sidebar
      get :summary, defaults: { format: :json }
      get :messages, defaults: { format: :json }
    end
  end
  resources :activities, only: [ :index ] do
    post :mark_all_read, on: :collection
    post :read, on: :member
  end
  resources :notes, only: [ :create, :update, :destroy ]
  resources :note_mentions, only: [ :destroy ]

  resources :drafts, only: [ :index, :show, :create, :update, :destroy ] do
    member do
      get  :edit
      get  :confirm
      post :send_now
    end
  end
  get "stats", to: "stats#show", as: :stats
  get "stats/data", to: "stats#data", as: :stats_data

  # Reports
  get "reports", to: "reports#index", as: :reports
  get "reports/weekly/:year/:week", to: "reports#show", defaults: { period_type: "weekly" }, as: :weekly_report
  get "reports/monthly/:year/:month", to: "reports#show", defaults: { period_type: "monthly" }, as: :monthly_report

  # CI orchestration
  get "ci", to: "ci#index", as: :ci
  get "ci/branches", to: "ci#branches", as: :ci_branches
  get "ci/topics/:id", to: "ci#topic", as: :ci_topic
  get "ci/stats", to: "ci#stats", as: :ci_stats

  # Help pages
  resources :help, only: [ :index, :show ], param: :slug

  # Script version endpoint
  get "scripts/:name/version", to: "scripts#version", as: :script_version
  # must precede the person/*email glob - it would otherwise swallow /commits
  # into the email itself
  get "person/*email/commits/contributions/:year", to: "person_commits#contributions", as: :person_commit_contributions, format: false
  get "person/*email/commits/activity/:date", to: "person_commits#daily_activity", as: :person_commit_activity, format: false
  get "person/*email/commits/activity/month/:year/:month", to: "person_commits#monthly_activity", as: :person_commit_monthly_activity, format: false
  get "person/*email/commits/activity/week/:year/:week", to: "person_commits#weekly_activity", as: :person_commit_weekly_activity, format: false
  get "person/*email/commits", to: "person_commits#show", as: :person_commits, format: false
  get "person/*email/contributions/:year", to: "people#contributions", as: :person_contributions, format: false
  get "person/*email/activity/:date", to: "people#daily_activity", as: :person_activity, format: false
  get "person/*email/activity/month/:year/:month", to: "people#monthly_activity", as: :person_monthly_activity, format: false
  get "person/*email/activity/week/:year/:week", to: "people#weekly_activity", as: :person_weekly_activity, format: false
  get "person/*email", to: "people#show", as: :person, format: false
  get "people/*email", to: redirect { |params, _req| "/person/#{params[:email]}" }, format: false

  get "team/:name/commits/contributions/:year", to: "team_commits#contributions", as: :team_commit_contributions
  get "team/:name/commits/activity/:date", to: "team_commits#daily_activity", as: :team_commit_activity
  get "team/:name/commits/activity/month/:year/:month", to: "team_commits#monthly_activity", as: :team_commit_monthly_activity
  get "team/:name/commits/activity/week/:year/:week", to: "team_commits#weekly_activity", as: :team_commit_weekly_activity
  get "team/:name/commits", to: "team_commits#show", as: :team_commits
  get "team/:name/contributions/:year", to: "teams_profile#contributions", as: :team_contributions
  get "team/:name/activity/:date", to: "teams_profile#daily_activity", as: :team_activity
  get "team/:name/activity/month/:year/:month", to: "teams_profile#monthly_activity", as: :team_monthly_activity
  get "team/:name/activity/week/:year/:week", to: "teams_profile#weekly_activity", as: :team_weekly_activity
  get "team/:name", to: "teams_profile#show", as: :team_profile

  # Authentication
  resource :session, only: [ :new, :create, :destroy ]
  resource :registration, only: [ :new, :create ]
  get "/verify", to: "verifications#show", as: :verification
  resource :password, only: [ :new, :create, :edit, :update ]

  # OmniAuth callbacks
  get "/auth/:provider/callback", to: "omniauth_callbacks#google_oauth2"

  post "messages/:id/read", to: "messages#read", as: :read_message
  get "messages/:id/content", to: "messages#content", as: :message_content
  get "messages/:id/patchset", to: "messages#patchset", as: :message_patchset
  resources :attachments, only: [ :show ] do
    get :content, on: :member
  end

  if Rails.env.development?
    mount LetterOpenerWeb::Engine, at: "/letter_opener"
  end
end
