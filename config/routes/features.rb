get 'profile/ai_reading', to: 'incoming_attention/ai_reading#edit',
                          as: :profile_ai_reading
post 'profile/ai_reading', to: 'incoming_attention/ai_reading#update'
get 'profile/emails', to: 'incoming_attention/emails#edit', as: :profile_emails
post 'profile/emails', to: 'incoming_attention/emails#update'

# The requester's choices about replies' AI readings.
scope 'request/:url_title', module: 'incoming_attention' do
  post 'attention_choice', to: 'choices#create', as: :attention_choice
  post 'attention_dismissal', to: 'choices#dismiss', as: :attention_dismissal
end

# Request deadlines.
scope 'deadlines/:request_id',
      module: 'deadlines',
      as: 'request_deadline',
      constraints: { request_id: /\d+/,
                     stage: /response|review_request|review/ } do
  post 'remind', to: 'reminders#create', as: 'remind'
  post 'complete', to: 'closures#create', as: 'complete'
  post 'reopen', to: 'closures#destroy', as: 'reopen'
  post ':stage', to: 'adjustments#create', as: ''
  post ':stage/restore', to: 'adjustments#destroy', as: 'restore'
end

# Authority groups; the admin pages are behind the admin sign-in.
get 'groups', to: 'authority_groups/groups#index', as: :authority_groups
scope 'groups/:tag',
      module: 'authority_groups',
      constraints: { tag: /[a-z0-9_]+/ } do
  get '', to: 'groups#show', as: :authority_group
  get ':section', to: 'groups#section',
                  as: :authority_group_section,
                  constraints: {
                    section: /documents|releases|authorities|foi_record/
                  }
end
scope 'admin', module: 'admin/authority_groups', as: 'admin' do
  get 'authority_groups', to: 'groups#index', as: 'authority_groups'
  post 'authority_groups/:category_id/hide', to: 'groups#hide',
                                             as: 'hide_authority_group'
  post 'authority_groups/:category_id/show', to: 'groups#unhide',
                                             as: 'unhide_authority_group'
  post 'bodies/:id/who_line', to: 'who_lines#update',
                              as: 'body_who_line',
                              constraints: { id: /\d+/ }
  resources :external_releases, controller: 'releases', except: :show do
    member do
      post 'hide'
      post 'unhide'
      post 'pin'
      post 'unpin'
    end
  end
  resources :external_release_imports, controller: 'imports',
                                       only: %i[index new create show] do
    member do
      post 'apply'
      post 'hide_releases'
      post 'unhide_releases'
    end
  end
end

# Authority page tabs. These routes are drawn before the main routes, so they
# win over /body/:url_name/:tag.
scope 'body/:url_name',
      module: 'authority_feeds',
      constraints: { url_name: %r{[^/]+} } do
  get 'documents', to: 'sections#documents', as: :public_body_documents
  get 'foi-record', to: 'sections#foi_record', as: :public_body_foi_record
end
scope 'admin', module: 'admin/authority_feeds', as: 'admin' do
  get 'authority_pages', to: 'pages#index', as: 'authority_pages'
  resources :authority_feeds, controller: 'feeds',
                              only: %i[edit update] do
    resources :imports, controller: 'imports',
                        only: %i[new create show] do
      member { post 'apply' }
    end
    resources :names, controller: 'names', only: %i[index create]
  end
  resources :authority_links, controller: 'links', except: %i[index show]
  post 'bodies/:id/holds', to: 'holds#update',
                           as: 'body_holds',
                           constraints: { id: /\d+/ }
end

# Topics, one per topic page, and a page for each question.
get 'topics', to: 'topics/topics#index', as: :topics
get 'topics/:slug', to: 'topics/topics#show',
                    as: :topic,
                    constraints: { slug: /[a-z0-9-]+/ }
get 'topics/:slug/who-holds-it', to: 'topics/topics#holders',
                                 as: :topic_holders,
                                 constraints: { slug: /[a-z0-9-]+/ }
get 'topics/:slug/:question', to: 'topics/topics#question',
                              as: :topic_question,
                              constraints: { slug: /[a-z0-9-]+/,
                                             question: /[a-z0-9-]+/ }

get 'request/:url_title/delete', to: 'disclosures/request_deletions#new',
                                 as: :request_deletion
post 'request/:url_title/delete', to: 'disclosures/request_deletions#create'

scope 'request/:url_title/publish/:message_id',
      module: 'disclosures',
      as: 'publish_reply',
      constraints: { message_id: /\d+/ } do
  get '', to: 'publishing#choose', as: ''
  post '', to: 'publishing#save_choice'
  get 'redact/:id', to: 'publishing#redact',
                    as: 'redact',
                    constraints: { id: /[a-z0-9]{12}/ }
  post 'redact/:id', to: 'publishing#apply_redaction',
                     constraints: { id: /[a-z0-9]{12}/ }
  get 'read/:id', to: 'publishing#read',
                  as: 'read',
                  constraints: { id: /[a-z0-9]{12}/ }
  post 'ask_admin/:id', to: 'publishing#ask_admin',
                        as: 'ask_admin',
                        constraints: { id: /[a-z0-9]{12}/ }
  post 'hide_name/:id', to: 'publishing#hide_name',
                        as: 'hide_name',
                        constraints: { id: /[a-z0-9]{12}/ }
  post 'start_again/:id', to: 'publishing#start_again',
                          as: 'start_again',
                          constraints: { id: /[a-z0-9]{12}/ }
  post 'try_again', to: 'publishing#try_again', as: 'try_again'
  get 'check', to: 'publishing#check', as: 'check'
  post 'check', to: 'publishing#publish'
  get 'published', to: 'publishing#published', as: 'published'
  get 'status', to: 'publishing#status',
                as: 'status',
                defaults: { format: :json }
end

scope 'admin/documents/:id', module: 'admin/disclosures',
                             as: 'admin_disclosure',
                             constraints: { id: /[a-z0-9]{12}/ } do
  get 'manage', to: 'documents#manage', as: 'manage_document'
  patch 'manage', to: 'documents#update'
  delete 'manage', to: 'documents#destroy'
  get 'edit', to: 'documents#edit', as: 'edit_document'
  post 'withdraw', to: 'documents#withdraw', as: 'withdraw_document'
end

# Documents: permissions in Ability::DocumentRules; ids are random public ids.
scope 'documents', module: 'disclosures', as: 'disclosure' do
  get '', to: 'documents#index', as: 'documents'
  post '', to: 'documents#create'
  get 'yours', to: 'documents#yours', as: 'your_documents'
  get 'review', to: '/admin/disclosures/reviews#index', as: 'document_reviews'
  post 'review', to: 'documents#request_review', as: 'request_document_review'
  scope ':id', constraints: { id: /[a-z0-9]{12}/ } do
    get '', to: 'documents#show', as: 'document'
    patch '', to: 'documents#update'
    delete '', to: 'documents#destroy'
    get 'manage', to: 'documents#manage', as: 'manage_document'
    patch 'manage', to: 'documents#update'
    delete 'manage', to: 'documents#destroy'
    get 'edit', to: 'documents#edit', as: 'edit_document'
    get 'download', to: 'documents#download', as: 'document_download'
    get 'pages/:page', to: 'documents#page_image',
                       as: 'document_page',
                       constraints: { page: /\d+/ }
    get 'thumbnail', to: 'documents#thumbnail', as: 'document_thumbnail'
    post 'publish', to: '/admin/disclosures/documents#publish',
                    as: 'publish_document'
    post 'withdraw', to: 'documents#withdraw', as: 'withdraw_document'
    post 'erase', to: '/admin/disclosures/documents#erase', as: 'erase_document'
    post 'unwanted', to: 'documents#unwanted', as: 'document_unwanted'
  end
end

scope 'manage/attachments/:attachment_id',
      module: 'attachment_management',
      as: 'manage_attachment',
      constraints: { attachment_id: /\d+/ } do
  get '', to: 'attachments#show', as: ''
  get 'current', to: 'attachments#current', as: 'current'
  get 'pages/:page', to: 'attachments#page',
                     as: 'page',
                     constraints: { page: /\d+/ }
  get 'redact', to: 'attachments#redact', as: 'redact'
  get 'text', to: 'attachments#edit_text', as: 'text'

  resources :revisions, only: [:create, :show], path: 'drafts' do
    member do
      get 'file'
      get 'pages/:page', action: :page, as: 'page', constraints: { page: /\d+/ }
      post 'apply'
      post 'discard'
    end
  end
end
