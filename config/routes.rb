Rails.application.routes.draw do
  namespace :admin do
    resources :imap_sync_states, only: [:index]
  end
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check
  get "messages/by-id/*message_id", to: "messages#by_message_id", as: :message_by_id, format: false

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Main application routes
  root "topics#index"
  
  resources :teams do
    resources :team_members, only: [:create, :destroy]
  end
  resource :username, only: [:update]
  patch "/password/current", to: "passwords#update_current", as: :update_current_password
  resources :topics, only: [:index, :show] do
    collection do
      get :search
      post :aware_bulk
      post :aware_all
    end
    member do
      post :aware
      post :read_all
    end
  end
  resources :activities, only: [:index] do
    post :mark_all_read, on: :collection
  end
  resources :notes, only: [:create, :update, :new] do
    collection do
      get :stack
    end
  end

  # Authentication
  resource :session, only: [:new, :create, :destroy]
  resource :registration, only: [:new, :create]
  get '/verify', to: 'verifications#show', as: :verification
  resource :password, only: [:new, :create, :edit, :update]
  resource :settings, only: [:show]
  resources :emails, only: [:create, :destroy] do
    post :primary, on: :member
  end
  resource :account_deletion, only: [:new, :create]

  # OmniAuth callbacks
  get '/auth/:provider/callback', to: 'omniauth_callbacks#google_oauth2'

  post "messages/:id/read", to: "messages#read", as: :read_message

  if defined?(PgHero)
    constraints AdminConstraint.new do
      mount PgHero::Engine, at: "/pghero"
    end
  end

  if Rails.env.development?
    mount LetterOpenerWeb::Engine, at: "/letter_opener"
  end
end
