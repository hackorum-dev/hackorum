Rails.application.routes.draw do
  namespace :admin do
    resources :imap_sync_states, only: [:index]
  end
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  get "up" => "rails/health#show", as: :rails_health_check

  if Rails.env.development?
    get "preview/maintenance" => ->(env) {
      PendingMigrationCatcher.new(nil).send(:render_maintenance_page, nil)
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

    resources :teams, only: [:index, :show, :create, :destroy] do
      resources :team_members, only: [:create, :destroy]
    end

    resource :username, only: [:update]
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
  get "stats", to: "stats#show", as: :stats
  get "stats/data", to: "stats#data", as: :stats_data

  # Help pages
  resources :help, only: [:index, :show], param: :slug
  get "person/*email/contributions/:year", to: "people#contributions", as: :person_contributions, format: false
  get "person/*email/activity/:date", to: "people#daily_activity", as: :person_activity, format: false
  get "person/*email", to: "people#show", as: :person, format: false
  get "people/*email", to: redirect { |params, _req| "/person/#{params[:email]}" }, format: false

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
