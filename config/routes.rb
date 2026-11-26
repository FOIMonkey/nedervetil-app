# config/routes.rb:
# Mapping URLs to controllers for FOIFA.
#
# Copyright (c) 2007 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

require 'sidekiq/web'

include AlaveteliFeatures::Constraints

# Allow easy extension from themes. Note these will have the highest priority.
$alaveteli_route_extensions.each do |f|
  load File.join('config', f)
end

class AdminConstraint # :nodoc:
  def matches?(request)
    Authentication::Session.admin?(request)
  end
end

class PreviewConstraint # :nodoc:
  def self.matches?(request)
    request.params[:preview].present? && request.params[:preview].to_i > 0
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
  match '/blog' => 'general#blog',
        :as => :blog,
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
  get '/search(/*combined)', to: documents_search, format: false, as: :search_redirect
  get '/advancedsearch', to: documents_search, as: :advanced_search
  match '/version.:format' => 'general#version',
        :as => :version,
        :via => :get

  #####

  ##### AtiNetwork controller
  match '/access-to-information-around-the-world' => 'ati_network#showcase',
        as: :ati_network_showcase,
        via: :get

  ##### Statistics controller
  get '/statistics' => 'statistics#index'
  get '/body_statistics' => redirect('/statistics#public_bodies'), :as => :public_bodies_statistics

  ##### Request controller
  # Public request listings are closed in private-archive mode.
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

  match '/request/search_ahead' => 'request#search_typeahead',
        :as => :search_ahead,
        :via => :get

  match '/request/:url_title' => 'request#show',
        :as => :show_request,
        :via => :get
  match '/request/:url_title/new' => 'request#show',
        :as => :show_new_request,
        :via => :get
  match '/request/:url_title/details' => 'request#details',
        :as => :details_request,
        :via => :get
  match '/request/:url_title/similar' => 'request#similar',
        :as => :similar_request,
        :via => :get

  match '/request/:request_url_title/response/:incoming_message_id/attach' \
        '/html/(:part(/*file_name))' => 'attachments#show_as_html',
        :format => false,
        :as => :get_attachment_as_html,
        :via => :get,
        :constraints => { :part => /\d+/ }
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

  match '/request/:url_title/upload' => 'upload_response#new',
        :as => :upload_response,
        :via => [:get, :post]

  match '/request/:url_title/download' => 'request#download_entire_request',
        :as => :download_entire_request,
        :via => :get

  get '/regulator_packs/download' => 'regulator_packs#show',
      as: :download_regulator_pack
  ####

  #### Citations controller
  resources :citations, only: [:index]

  scope path: 'request/:url_title' do
    resources :citations,
      only: [:new, :create],
      defaults: { resource: 'InfoRequest' }
  end

  resources :info_request_batch, :only => :show do
    resources :citations,
      only: [:new, :create],
      defaults: { resource: 'InfoRequestBatch' }
  end
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

  #### Projects
  constraints FeatureConstraint.new(:projects) do
    match '/p/:token' => 'projects/invites#create',
          as: :project_invite,
          via: :get

    scope module: :projects do
      resources :projects, only: [:show] do
        resource :extract, only: [:show, :create, :edit, :update] do
          patch :skip
        end
        resource :classify, only: [:show, :create, :edit, :update] do
          patch :skip
          get :message
        end

        resource :contributors, only: [:destroy]

        resource :dataset, controller: :dataset, only: [:show, :edit, :update]
        resource :leaderboard, only: [:show], format: true
      end
    end
  end
  ####

  namespace :health do
    resources :checks, :only => [:index]
    resources :metrics, :only => [:index], :defaults => { :format => 'txt' }
  end
  get '/health_checks' => redirect('/health/checks')

  resources :request, :only => [], param: :url_title do
    resource :report, :only => [:new, :create]
    resource :widget, :only => [:new, :show]
    resources :widget_votes, :only => [:create]
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
  match '/profile/set_photo' => 'user#set_profile_photo',
        :as => :set_profile_photo,
        :via => [:get, :post]
  match '/profile/clear_photo' => 'user#clear_profile_photo',
        :as => :clear_profile_photo,
        :via => :post
  match '/user/:url_name/photo.png' => 'user#get_profile_photo',
        :as => :get_profile_photo,
        :via => :get
  match '/profile/draft_photo/:id.png' => 'user#get_draft_profile_photo',
        :as => :get_draft_profile_photo,
        :via => :get

  namespace :users do
    get 'email_alerts/disable/:token',
        to: 'email_alerts#destroy',
        as: :disable_email_alerts
  end

  namespace :users, path: 'profile' do
    resource :name, only: [:edit, :update]
  end

  namespace :profile, :module => 'user_profile' do
    resource :about_me, :only => [:edit, :update], :controller => 'about_me'
  end

  # Legacy route for setting about_me
  match '/profile/set_about_me' => redirect('/profile/about_me/edit'),
        :as => :set_profile_about_me,
        :via => [:get, :post]

  match '/profile/set_receive_alerts' => 'user#set_receive_email_alerts',
        :as => :set_receive_email_alerts,
        :via => [:get, :post]

  match '/profile/river' => 'user#river',
        :as => :river,
        :via => :get
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
  resource :change_request, :only => [:new, :create], :controller => 'public_body_change_requests'
  match 'change_request/new/:body' => 'public_body_change_requests#new',
        :as => :new_change_request_body,
        :via => :get

  #### Comment controller
  get '/request/:url_title/annotate' => 'comments#new',
      as: :new_comment,
      type: 'request'
  post '/request/:url_title/annotate' => 'comments#preview',
       as: :comments,
       type: 'request',
       constraints: PreviewConstraint
  post '/request/:url_title/annotate' => 'comments#create',
       type: 'request'
  ####

  #### Services controller
  match '/country_message' => 'services#other_country_message',
        :as => :other_country_message,
        :via => :get
  match '/hidden_user_explanation' => 'services#hidden_user_explanation',
        :as => :hidden_user_explanation,
        :via => :get
  ####

  #### Track controller (retired in private-archive mode)
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

  #### RequestGame controller
  match '/categorise/play' => 'request_game#play',
        :as => :categorise_play,
        :via => [:get, :post]
  match '/request/:url_title/categorise' => 'request_game#show',
        :as => :categorise_request,
        :via => :get
  match '/categorise/stop' => 'request_game#stop',
        :as => :categorise_stop,
        :via => :post
  ####

  #### Announcement controller
  resources :announcements, :only => [:destroy]
  ####

  #### Admin::BlogPosts controller
  namespace :admin do
    resources :blog_posts, only: [:index, :edit, :update]
  end
  ####

  #### Admin::Changelog controller
  namespace :admin do
    resources :changelog, only: [:index]
  end

  #### Admin::Citations controller
  namespace :admin do
    resources :citations, only: [:index, :edit, :update, :destroy]
  end
  ####

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

  direct :admin_note_parent do |note|
    if note.notable_tag
      admin_tag_path(tag: note.notable_tag)
    elsif note.notable
      url_for([:admin, note.notable])
    else
      admin_general_index_path
    end
  end

  #### Admin::Projects controller
  namespace :admin do
    resources :projects, except: [:new, :create] do
      scope module: :projects do
        resources :submissions, only: [:destroy]
      end
    end
  end
  ####

  #### Admin::PostRedirectsController
  namespace :admin do
    resources :post_redirects, only: [:destroy]
  end
  ####

  #### Admin::TwoFactor controller
  namespace :admin do
    resource :two_factor, only: :show, controller: 'two_factor'
  end
  ####

  #### AdminPublicBody controller
  scope '/admin', :as => 'admin' do
    resources :bodies,
    :controller => 'admin_public_body' do
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

  #### AdminHoliday controller
  scope '/admin', :as => 'admin' do
    resources :holidays,
      :controller => 'admin_holidays'
  end
  ####

  #### AdminHolidayImports controller
  scope '/admin', :as => 'admin' do
    resources :holiday_imports,
      :controller => 'admin_holiday_imports',
      :only => [:new, :create]
  end
  ####

  #### AdminPublicBodyChangeRequest controller
  scope '/admin', :as => 'admin' do
    resources :change_requests,
      :controller => 'admin_public_body_change_requests',
      :only => [:index, :destroy, :edit, :update]
  end
  ####

  #### AdminGeneral controller
  match '/admin' => 'admin_general#index',
        :as => :admin_general_index,
        :via => :get
  match '/admin/timeline' => 'admin_general#timeline',
        :as => :admin_timeline,
        :via => :get
  match '/admin/stats' => 'admin_general#stats',
        :as => :admin_stats,
        :via => :get
  ####

  #### AdminRequest controller
  scope '/admin', :as => 'admin' do
    resources :requests,
      :controller => 'admin_request',
    :except => [:new, :create] do
      post 'move', :on => :member
      post 'generate_upload_url', :on => :member
      post 'hide', :on => :member
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

  #### AdminComment controller
  scope '/admin', :as => 'admin' do
    resources :comments,
      :controller => 'admin_comment',
      :only => [:index, :edit, :update, :destroy]
  end
  ####

  #### AdminRawEmail controller
  scope '/admin', :as => 'admin' do
    resources :raw_emails,
      :controller => 'admin_raw_email',
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

  #### AdminInfoRequestEvent controller
  scope '/admin', :as => 'admin' do
    resources :info_request_events,
      :controller => 'admin_info_request_event',
      :only => [:edit, :index, :update]
  end

  #### AdminIncomingMessage controller
  scope '/admin', :as => 'admin' do
    resources :incoming_messages,
      :controller => 'admin_incoming_message',
      :only => [:edit, :update, :destroy]
    resource :incoming_messages,
      :controller => 'admin_incoming_message' do
        post 'bulk_destroy'
      end
  end
  ####

  #### Admin::IncomingMessages::RedeliveriesController
  namespace :admin do
    resources :incoming_messages, only: [] do
      scope module: :incoming_messages do
        resource :redelivery, only: [:create]
      end
    end
  end
  ####


  #### AdminOutgoingMessage controller
  scope '/admin', :as => 'admin' do
    resources :outgoing_messages,
      :controller => 'admin_outgoing_message',
    :only => [:index, :edit, :update, :destroy] do
      post 'resend', :on => :member
    end
  end
  ####

  #### AdminMailServerLog controller
  scope '/admin', :as => 'admin' do
    resources :mail_server_logs,
      :controller => 'admin_mail_server_log',
    :only => [:index, :edit, :update]
  end
  ####

  #### AdminFoiAttachment controller
  namespace :admin do
    resources :foi_attachments, path: :attachments,
                                only: [:edit, :update] do
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

  #### AdminUser controller
  scope '/admin', :as => 'admin' do
    resources :users,
      :controller => 'admin_user',
    :except => [:new, :create, :destroy] do
      get 'active', :on => :collection
      get 'banned', :on => :collection
      get 'closed', :on => :collection
      get 'show_bounce_message', :on => :member
      post 'clear_bounce', :on => :member
      post 'clear_profile_photo', :on => :member
      post 'modify_comment_visibility', :on => :collection
      resources :slugs, controller: 'admin_user_slug', only: :destroy
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

  #### AdminUsersSessions controller
  scope '/admin', :as => 'admin' do
    resource :users_sessions,
      :controller => 'admin_users_sessions',
      :only => [:create, :destroy]
  end
  ####

  #### Admin::Users::SignIns controller
  namespace :admin do
    scope module: 'users' do
      resources :sign_ins, only: [:index]
    end
  end
  ####

  #### AdminTrack controller
  scope '/admin', :as => 'admin' do
    resources :tracks,
      :controller => 'admin_track',
      :only => [:index, :destroy]
  end
  ####

  #### Admin::CensorRules controller
  namespace :admin do
    resources :censor_rules
  end

  #### AdminSpamAddresses controller
  scope '/admin', :as => 'admin' do
    resources :spam_addresses,
      :controller => 'admin_spam_addresses',
      :only => [:index, :create, :destroy]
  end
  ####

  #### AdminAnnouncement controller
  scope '/admin', :as => 'admin' do
    resources :announcements, :controller => 'admin_announcements'
  end
  ####

  #### Admin::Snippets controller
  namespace :admin do
    scope module: :outgoing_messages do
      resources :snippets, except: [:show]
    end
  end
  ####

  #### Admin::Insights controller
  namespace :admin do
    resources :info_requests, only: [], path: 'requests' do
      resources :insights, only: [:show, :new, :create, :destroy]
    end
  end
  ####

  #### Pro Pages
  namespace :alaveteli_pro, path: :pro, as: :pro do
    resources :pages, only: [:show]
  end

  #### Unified Inbox (alaveteli_pro naming kept for theme compatibility)
  namespace :alaveteli_pro, path: 'pro' do
    get :dashboard, to: 'dashboard#index'
    resources :draft_info_requests, :only => [:create, :update, :destroy]
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
    resources :public_bodies, :only => [:index]
  end

  scope path: :pro do
    # Show a batch request in the inbox context
    match '/info_request_batches/:id' => 'info_request_batch#show',
          :as => :show_alaveteli_pro_batch_request,
          :via => :get,
          :defaults => { :pro => '1' }

    # Show the authority selection screen in the inbox context
    match '/select_authority' => 'request#select_authority',
          :as => :alaveteli_pro_select_authority,
          :via => :get,
          :defaults => { :pro => '1' }
  end
  ####

  #### Admin topic guides and topic content controllers
  namespace :admin do
    resources :topic_guides, except: [:show]
    resources :topic_pages, path: 'topics', except: [:show] do
      resources :topic_holders, path: 'holders', except: %i[index show]
      resources :topic_questions, path: 'questions', except: %i[index show]
      resources :topic_sources, path: 'sources', except: %i[index show]
      resources :topic_routes, path: 'routes', except: %i[index show]
    end
    resources :topic_datasets, path: 'datasets', except: [:show]
    resources :topic_changes, path: 'topic_history', only: [:index]
  end
end
