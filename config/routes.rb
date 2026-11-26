# config/routes.rb:
# Mapping URLs to controllers for FOIFA.
#
# Copyright (c) 2007 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

require 'sidekiq/web'

# Allow easy extension from themes. Note these will have the highest priority.
$alaveteli_route_extensions.each do |f|
  load File.join('config', f)
end

class AdminConstraint # :nodoc:
  def matches?(request)
    Authentication::Session.admin?(request)
  end
end

Rails.application.routes.draw do
  devise_for :users, skip: :all

  draw :features
  draw :redirects

  mount Sidekiq::Web => '/sidekiq', constraints: AdminConstraint.new

  root to: 'general#frontpage'

  #### General controller
  root :to => 'general#frontpage',
       :as => :frontpage,
       :via => :get
  # Requests are private, so the published documents are the only search.
  # The old search URLs put their words in the path, with the kind of result
  # and the sort order as trailing segments, or in ?query=.
  documents_search = redirect do |params, request|
    words = request.params['query'].presence || params[:combined].to_s.
      # rubocop:disable Layout/LineLength -- a regex
      sub(%r{(/(all|requests|users|bodies))?(/(newest|described|relevant))?(/advanced)?\z}, '')
    # rubocop:enable Layout/LineLength
    path = '/documents'
    words.present? ? "#{path}?q=#{ERB::Util.url_encode(words)}" : path
  end
  get '/search(/*combined)', to: documents_search, format: false
  get '/advancedsearch', to: documents_search
  match '/version.:format' => 'general#version',
        :as => :version,
        :via => :get

  #####

  # The statistics page was removed and /statistics is a 404, as it was while
  # switched off. This old link keeps the redirect it has always given.
  get '/body_statistics' => redirect('/statistics#public_bodies')

  ##### Request controller
  # The public request listings are gone; their URLs lead to the documents.
  get '/browse' => redirect('/documents')
  get '/list(/*rest)' => redirect('/documents'), format: false

  match '/select_authority' => 'request#select_authority',
        :as => :select_authority,
        :via => :get

  match '/new' => 'request#new',
        :as => :new_request,
        :via => [:get, :post]
  match '/new/:url_name' => 'request#new',
        :as => :new_request_to_body,
        :via => [:get, :post]

  match '/request/:url_title' => 'request#show',
        :as => :show_request,
        :via => :get
  match '/request/:url_title/new' => 'request#show',
        :as => :show_new_request,
        :via => :get
  match '/request/:url_title/details' => 'request#details',
        :as => :details_request,
        :via => :get

  match '/request/:request_url_title/response/:incoming_message_id/attach' \
        '/:part(/*file_name)' => 'attachments#show',
        :format => false,
        :as => :get_attachment,
        :via => :get,
        :constraints => { :part => /\d+/ }

  #### Attachment controller
  resources :attachment_masks, only: [], path: :attachments do
    get 'wait', on: :member, as: :wait_for
    get 'done', on: :member
  end
  ####

  match '/request_event/:info_request_event_id' => 'request#show_request_event',
        :as => :info_request_event,
        :via => :get

  match '/request/:url_title/download' => 'request#download_entire_request',
        :as => :download_entire_request,
        :via => :get

  get '/regulator_packs/download' => 'regulator_packs#show',
      as: :download_regulator_pack
  ####

  #### InfoRequestBatch controller
  resources :info_request_batch, :only => :show
  ####

  #### Classifications controller
  scope path: 'request/:url_title' do
    resources :classifications, only: [:create], param: :described_state do
      get :message, on: :member
    end
  end
  ####

  #### Followups controller
  match '/request/:request_url_title/followups/new' => 'followups#new',
        :as => :new_request_followup,
        :via => :get
  match '/request/:request_url_title/followups/new/:incoming_message_id' =>
          'followups#new',
        :as => :new_request_incoming_followup,
        :via => :get
  match '/request/:request_url_title/followups/preview' => 'followups#preview',
        :as => :preview_request_followups,
        :via => :post
  match '/request/:request_url_title/followups' => 'followups#create',
        :as => :request_followups,
        :via => :post
  ####

  namespace :health do
    resources :checks, :only => [:index]
    resources :metrics, :only => [:index], :defaults => { :format => 'txt' }
  end
  get '/health_checks' => redirect('/health/checks')

  resources :request, :only => [], param: :url_title do
    resource :report, :only => [:new, :create]
  end

  #### OutgoingMessage controller
  resources :outgoing_messages, :only => [] do
    resource :delivery_status, :only => [:show], :module => 'outgoing_messages'
  end
  ####

  #### User controller
  # Use /profile for things to do with the currently signed in user.
  # Use /user/XXXX for things that anyone can see about that user.
  # Note that /profile isn't indexed by search (see robots.txt)
  devise_scope :user do
    # Devise failure/timeout helpers point to the existing public URLs.
    get '/profile/sign_in', to: 'users/sessions#new', as: :new_user_session
    get '/profile/change_password', to: 'users/passwords#new',
                                    as: :new_user_password
    get '/profile/sign_in', to: 'users/sessions#new', as: :signin
    post '/profile/sign_in', to: 'users/sessions#create', as: :create_session
    get '/profile/sign_out', to: 'users/sessions#confirm_destroy', as: :signout
    match '/profile/sign_out', to: 'users/sessions#destroy',
                               via: [:post, :delete]
    get '/profile/sign_up', to: 'users/registrations#new', as: :signup
    post '/profile/sign_up', to: 'users/registrations#create'
    get '/profile/change_password', to: 'users/passwords#new',
                                    as: :new_password_change
    post '/profile/change_password', to: 'users/passwords#create',
                                     as: :password_changes
    get '/profile/change_password/:id', to: 'users/passwords#edit',
                                        as: :edit_password_change
    match '/profile/change_password/:id', to: 'users/passwords#update',
                                          via: [:patch, :put],
                                          as: :password_change
    get '/c/:email_token', to: 'users/confirmations#show', as: :confirm
    post '/c/:email_token', to: 'users/confirmations#update'
    get '/profile/confirmation', to: 'users/confirmations#new',
                                 as: :new_user_confirmation
    post '/profile/confirmation', to: 'users/confirmations#create',
                                  as: :user_confirmation
    get '/profile/sign_in/two_factor', to: redirect('/profile/sign_in'),
                                       as: :signin_two_factor
  end

  resource :one_time_password, only: [:new, :show, :create, :destroy],
                               path: '/profile/two_factor'
  post '/profile/two_factor/start', to: 'one_time_passwords#start',
                                    as: :start_one_time_password
  resource :one_time_password_backup_codes,
           only: [:show, :create],
           path: '/profile/two_factor/backup_codes',
           controller: 'one_time_passwords/backup_codes'
  match '/tor', to: 'user#tor', via: :get

  match '/user/:url_name' => 'user#show',
        :as => :show_user,
        :via => :get
  match '/user/:url_name/profile' => 'user#show',
        :as => :show_user_profile,
        :view => 'profile',
        :via => :get
  match '/user/:url_name/requests' => 'user#show',
        :as => :show_user_requests,
        :view => 'requests',
        :via => :get
  match '/profile/change_email' => 'users/email_changes#new',
        :as => :signchangeemail,
        :via => :get
  post '/profile/change_email', to: 'users/email_changes#create'
  match '/profile/change_email/confirm/:email_token' =>
          'users/email_changes#show',
        :as => :confirm_email_change,
        :via => :get
  match '/profile/change_email/confirm/:email_token' =>
          'users/email_changes#update',
        :via => :post

  namespace :users do
    get 'email_alerts/disable/:token',
        to: 'email_alerts#destroy',
        as: :disable_email_alerts
  end

  namespace :users, path: 'profile' do
    resource :name, only: [:edit, :update]
  end

  # A form only: a link that changed a setting could be followed from
  # another site.
  match '/profile/set_receive_alerts' => 'user#set_receive_email_alerts',
        :as => :set_receive_email_alerts,
        :via => :post

  ####

  #### PublicBody controller
  match '/body/search_ahead' => 'public_body#search_typeahead',
        :as => :search_ahead_bodies,
        :via => :get
  match '/body' => 'public_body#list',
        :as => :list_public_bodies,
        :via => :get
  match '/body/list/all' => 'public_body#list',
        :as => :list_public_bodies_default,
        :via => :get
  match '/body/list/:tag' => 'public_body#list',
        :as => :list_public_bodies_by_tag,
        :via => :get
  match '/local/:tag' => 'public_body#list_redirect',
        :as => :list_public_bodies_redirect,
        :via => :get
  match '/body/all-authorities.csv' => 'public_body#list_all_csv',
        :as => :all_public_bodies_csv,
        :via => :get
  match '/body/:url_name' => 'public_body#show',
        :as => :show_public_body, :view => 'all',
        :via => :get
  match '/body/:url_name/all' => 'public_body#show',
        :as => :show_public_body_all,
        :view => 'all',
        :via => :get
  match '/body/:url_name/successful' => 'public_body#show',
        :as => :show_public_body_successful,
        :view => 'successful',
        :via => :get
  match '/body/:url_name/unsuccessful' => 'public_body#show',
        :as => :show_public_body_unsuccessful,
        :view => 'unsuccessful',
        :via => :get
  match '/body/:url_name/awaiting' => 'public_body#show',
        :as => :show_public_body_awaiting,
        :view => 'awaiting',
        :via => :get
  match '/body/:url_name/:tag' => 'public_body#show',
        :as => :show_public_body_tag,
        :via => :get
  match '/body/:url_name/:tag/:view' => 'public_body#show',
        :as => :show_public_body_tag_view,
        :via => :get
  ####

  #### PublicBodyChangeRequest controller
  resource :change_request, :only => [:new, :create],
                            :controller => 'public_body_change_requests'
  match 'change_request/new/:body' => 'public_body_change_requests#new',
        :as => :new_change_request_body,
        :via => :get

  #### Old feeds
  # Tracks and their feeds were removed (see doc/FORK.md). The list, authority
  # and search feeds lead to the published documents feed; the rest 404.
  documents_feed = redirect(status: 302) do |path_params, _request|
    Rails.application.routes.url_helpers.disclosure_documents_path(
      format: path_params[:format], feed: '1',
      body: path_params[:url_name], q: path_params[:query_array]
    )
  end
  get '/feed/list/:view' => documents_feed, :view => nil
  get '/feed/body/:url_name' => documents_feed
  get '/feed/search/:query_array' => documents_feed,
      :constraints => { :query_array => /.*/ }
  ####

  #### Refusal Advice controller
  resource :refusal_advice, only: [:create], controller: 'refusal_advice'
  ####

  #### Help controller
  match '/help/unhappy(/:url_title)' => 'help#unhappy',
        :as => :help_unhappy,
        :via => :get
  match '/help/about' => 'help#about',
        :as => :help_about,
        :via => :get
  match '/help/alaveteli' => 'help#alaveteli',
        :as => :help_alaveteli,
        :via => :get
  match '/help/contact' => 'help#contact',
        :as => :help_contact,
        :via => [:get, :post]
  match '/help/officers' => 'help#officers',
        :as => :help_officers,
        :via => :get
  match '/help/requesting' => 'help#requesting',
        :as => :help_requesting,
        :via => :get
  match '/help/privacy' => 'help#privacy',
        :as => :help_privacy,
        :via => :get
  match '/help/api' => 'help#api',
        :as => :help_api,
        :via => :get
  match '/help/credits' => 'help#credits',
        :as => :help_credits,
        :via => :get

  match '/help/pro' => 'help#pro',
        as: :help_pro,
        via: :get

  # The theme's help pack (lib/help_site.rb): its front page, sections,
  # answers, words and guide. Any other address goes on to the pages below.
  get '/help' => 'help_site#show', as: :help_home
  get '/help' => 'help_site#show', as: :help
  get '/help/search' => 'help_site#search', defaults: { format: 'json' },
      as: :help_search
  get '/help/:section(/:answer)' => 'help_site#show',
      constraints: HelpSite::PageConstraint

  match '/help/:template' => 'help#action',
        :as => :help_general,
        :via => :get,
        :template => /[-_a-z]+/
  ####

  #### Holiday controller
  match '/due_date/:holiday' => 'holiday#due_date',
        :as => :due_date,
        :via => :get
  ####

  #### Announcement controller
  resources :announcements, :only => [:destroy]
  ####

  #### Admin::Changelog controller
  namespace :admin do
    resources :changelog, only: [:index]
  end

  #### Admin::Debug controller
  namespace :admin do
    resources :debug, only: :index
  end
  ####

  #### AdminTag controller
  get '/admin/tags/suggestions' => 'admin/tags#suggestions',
      as: :suggestions_admin_tags

  namespace :admin do
    resources :tags, param: :tag, only: [:index, :show],
                     constraints: { tag: /.+/ }
  end
  ####

  #### Admin::InfoRequestBatches controller
  namespace :admin do
    resources :info_request_batches, path: :batches, only: [:show]
  end

  #### AdminNote controller
  namespace :admin do
    resources :notes, except: [:show]
  end

  #### Admin::TopicGuides controller
  namespace :admin do
    resources :topic_guides, except: [:show]
  end

  #### Admin topic content controllers
  namespace :admin do
    resources :topic_pages, path: 'topics', except: [:show] do
      resources :topic_holders, path: 'holders', except: %i[index show]
      resources :topic_questions, path: 'questions', except: %i[index show]
      resources :topic_sources, path: 'sources', except: %i[index show]
      resources :topic_routes, path: 'routes', except: %i[index show]
    end
    resources :topic_datasets, path: 'datasets', except: [:show]
    resources :topic_changes, path: 'topic_history', only: [:index]
  end

  direct :admin_note_parent do |note|
    if note.notable_tag
      admin_tag_path(tag: note.notable_tag)
    elsif note.notable
      url_for([:admin, note.notable])
    else
      admin_general_index_path
    end
  end

  #### Admin::TwoFactor controller
  namespace :admin do
    resource :two_factor, only: :show, controller: 'two_factor'
  end
  ####

  #### Admin::PublicBodies controller
  scope '/admin', :as => 'admin' do
    resources :bodies,
    :controller => 'admin/public_bodies' do
      get 'import_csv', :on => :collection
      post 'import_csv', :on => :collection
      resources :censor_rules,
        :controller => 'admin/censor_rules',
        :only => [:new, :create]
    end
  end
  direct :admin_public_body do |pb|
    admin_body_path(pb)
  end
  ####

  #### Admin::Categories controller
  namespace :admin do
    resources :categories do
      post 'reorder', on: :member
    end
  end
  ####

  #### Admin::Holidays controller
  scope '/admin', :as => 'admin' do
    resources :holidays,
      :controller => 'admin/holidays',
      :except => [:show]
  end
  ####

  #### Admin::HolidayImports controller
  scope '/admin', :as => 'admin' do
    resources :holiday_imports,
      :controller => 'admin/holiday_imports',
      :only => [:new, :create] do
        post :preview, :on => :collection
      end
  end
  ####

  #### Admin::PublicBodyChangeRequests controller
  scope '/admin', :as => 'admin' do
    resources :change_requests,
      :controller => 'admin/public_body_change_requests',
      :only => [:index, :destroy, :edit, :update]
  end
  ####

  #### Admin::General controller
  match '/admin' => 'admin/general#index',
        :as => :admin_general_index,
        :via => :get
  get '/admin/jump' => 'admin/jump#show',
      :as => :admin_jump
  get '/admin/triage/:kind/:id' => 'admin/triage#show',
      :as => :admin_triage
  match '/admin/timeline' => 'admin/general#timeline',
        :as => :admin_timeline,
        :via => :get
  match '/admin/stats' => 'admin/general#stats',
        :as => :admin_stats,
        :via => :get
  ####

  #### Admin::Requests controller
  scope '/admin', :as => 'admin' do
    resources :requests,
      :controller => 'admin/requests',
      :except => [:new, :create] do
      post 'move', :on => :member
      patch 'prominence', :on => :member
      post 'revert_report', :on => :member
      resources :censor_rules,
        :controller => 'admin/censor_rules',
        :only => [:new, :create] do
        resources :redactions,
          :controller => 'admin/censor_rules/redactions',
          :only => [:index]
      end
    end
  end
  direct :admin_info_request do |ir|
    admin_request_path(ir)
  end
  ####

  #### Admin::RawEmails controller
  scope '/admin', :as => 'admin' do
    resources :raw_emails,
      :controller => 'admin/raw_emails',
      :only => [:show]
  end
  ####

  #### Admin::RawEmails::Erasures controller
  namespace :admin do
    resources :raw_emails, only: [] do
      scope module: :raw_emails do
        resource :erasure, only: [:create]
      end
    end
  end
  ####

  #### Admin::InfoRequestEvents controller
  scope '/admin', :as => 'admin' do
    resources :info_request_events,
      :controller => 'admin/info_request_events',
      :only => [:edit, :index, :update]
  end

  #### Admin::IncomingMessages controller
  scope '/admin', :as => 'admin' do
    resources :incoming_messages,
      :controller => 'admin/incoming_messages',
      :only => [:edit, :update, :destroy]
    resource :incoming_messages,
      :controller => 'admin/incoming_messages',
      :only => [] do
        post 'bulk_destroy'
      end
  end
  ####

  #### Admin::IncomingMessages::RedeliveriesController
  namespace :admin do
    resources :incoming_messages, only: [] do
      scope module: :incoming_messages do
        resource :redelivery, only: [:create]
        resource :reading, only: [:create]
      end
    end
  end
  ####

  #### Admin::OutgoingMessages controller
  scope '/admin', :as => 'admin' do
    resources :outgoing_messages,
      :controller => 'admin/outgoing_messages',
      :only => [:index, :edit, :update, :destroy] do
      post 'resend', :on => :member
    end
  end
  ####

  #### Admin::MailServerLogs controller
  scope '/admin', :as => 'admin' do
    resources :mail_server_logs,
      :controller => 'admin/mail_server_logs',
      :only => [:index, :edit, :update]
  end
  ####

  #### AdminFoiAttachment controller
  namespace :admin do
    resources :foi_attachments, path: :attachments,
                                only: [:edit] do
      get :download_unmasked, on: :member
      resource :prominence, controller: 'foi_attachments/prominence',
                            only: [:update]
      resource :masks, controller: 'foi_attachments/masks',
                       only: [:create]
      resources :erasures, controller: 'foi_attachments/erasures',
                           only: [:create]
    end
  end
  ####

  #### Admin::Users controller
  scope '/admin', :as => 'admin' do
    resources :users,
      :controller => 'admin/users',
      :except => [:new, :create, :destroy] do
        get 'active', :on => :collection
        get 'banned', :on => :collection
        get 'closed', :on => :collection
        get 'show_bounce_message', :on => :member
        post 'clear_bounce', :on => :member
        resources :slugs, controller: 'admin/users/slugs', only: :destroy
        resources :censor_rules,
          :controller => 'admin/censor_rules',
          :only => [:new, :create]
      end
  end
  ####

  #### Admin::Users::Suspensions controller
  #### Admin::Users::Closures controller
  #### Admin::Users::Anonymisations controller
  #### Admin::Users::Erasures controller
  namespace :admin do
    resources :users, only: [], module: :users do
      resource :suspension, only: [:create]
      resource :closure, only: [:create]
      resource :anonymisation, only: [:create]
      resource :erasure, only: [:create]
    end
  end
  ####

  #### Admin::Users::SignIns controller
  namespace :admin do
    scope module: 'users' do
      resources :sign_ins, only: [:index]
    end
  end
  ####

  #### Admin::CensorRules controller
  namespace :admin do
    resources :censor_rules, except: [:show]
  end

  #### Admin::SpamAddresses controller
  scope '/admin', :as => 'admin' do
    resources :spam_addresses,
      :controller => 'admin/spam_addresses',
      :only => [:index, :create, :destroy]
  end
  ####

  #### Admin::Announcements controller
  scope '/admin', :as => 'admin' do
    resources :announcements, :controller => 'admin/announcements',
                              :except => [:show]
  end
  ####

  #### Admin::Snippets controller
  namespace :admin do
    scope module: :outgoing_messages do
      resources :snippets, except: [:show]
    end
  end
  ####

  #### Pro Pages
  namespace :alaveteli_pro, path: :pro, as: :pro do
    resources :pages, only: [:show]
  end

  #### Alaveteli Pro
  namespace :alaveteli_pro, path: 'pro' do
    get :dashboard, to: 'dashboard#index'
    resources :draft_info_requests, :only => [:destroy]
    resources :info_requests, only: [:new, :create, :index] do
      get :preview, on: :new # /info_request/new/preview
    end
    scope path: 'info_requests/:url_title' do
      resources :classifications, only: :create, param: :described_state do
        get :message, on: :member
      end
    end
    resources :batch_request_authority_searches, :only => [:index, :new]
    resources :draft_info_request_batches, :only => [:create, :update] do
      collection do
        put :update_bodies
      end
    end
    resources :info_request_batches, :only => [:new, :create] do
      get :preview, on: :new # /info_request_batch/new/preview
      resource :batch_download, only: [:show], format: true, path: 'download'
    end
  end

  scope path: :pro do
    # So that we can show a batch request using the existing controller from
    # the pro context
    match '/info_request_batches/:id' => 'info_request_batch#show',
          :as => :show_alaveteli_pro_batch_request,
          :via => :get,
          :defaults => { :pro => '1' }
  end
  ####
end
