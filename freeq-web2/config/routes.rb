Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  root to: redirect("/chat", status: 302)

  # AT Protocol handles (e.g. nandi.uk, alice.bsky.social) are valid IRC nicks
  # and contain dots. Rails' default segment constraint stops at `.` (format
  # separator), which would turn /chat/dm/nandi.uk into nick="nandi" format="uk"
  # and break DID resolution / E2EE. Allow any non-slash character.
  nick_segment = { nick: /[^\/]+/ }

  resources :chat, only: %i[index], path: "chat"
  get "chat/:channel", to: "chat#show", as: :chat_channel
  get "chat/dm/:nick", to: "chat#dm", as: :chat_dm, constraints: nick_segment, format: false
  # Mutations used by the JS reaction picker (and available as plain POST APIs).
  post "chat/:channel/react", to: "chat#react"
  post "chat/:channel/unreact", to: "chat#unreact"

  # Channel policy info.
  get "api/did/:nick", to: "api#did_for_nick", constraints: nick_segment, format: false
  post "api/dm/send", to: "api#dm_send"
  # E2EE pre-key bundles — browser hits same-origin; we proxy to upstream REST
  # (avoids CORS and keeps getServerOrigin() = window.location.origin correct).
  get "api/v1/keys/*did", to: "api#get_keys", format: false
  post "api/v1/keys", to: "api#upload_keys"
  get "api/irc_status", to: "api#irc_status"
  # AT Protocol OAuth.
  get "login", to: "sessions#new"
  post "login", to: "sessions#create"
  get "auth/callback", to: "sessions#callback"
  post "logout", to: "sessions#destroy"
  get ".well-known/oauth-client-metadata", to: "sessions#client_metadata"
end
