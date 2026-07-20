Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # Progressive Web App — SW must not be year-cached (public_file_server).
  get "manifest", to: "pwa#manifest", as: :pwa_manifest, defaults: { format: :json }
  get "service-worker", to: "pwa#service_worker", as: :pwa_service_worker

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

  # Channel policy info + other same-origin API.
  get "api/policy/:channel", to: "api#policy", constraints: { channel: /[^\/]+/ }, format: false
  get "api/did/:nick", to: "api#did_for_nick", constraints: nick_segment, format: false
  post "api/dm/send", to: "api#dm_send"
  # E2EE pre-key bundles — browser hits same-origin; we proxy to upstream REST
  # (avoids CORS and keeps getServerOrigin() = window.location.origin correct).
  get "api/v1/keys/*did", to: "api#get_keys", format: false
  post "api/v1/keys", to: "api#upload_keys"
  get "api/irc_status", to: "api#irc_status"
  # Temporary OAuth diagnostics (remove when login stickiness is solid).
  get "debug/auth", to: "debug_auth#show"
  get "debug/impersonate_latest", to: "debug_auth#impersonate_latest"
  get "debug/clear_fat_cookies", to: "debug_auth#clear_fat_cookies"

  # AT Protocol OAuth.
  # Login start is GET: OAuth initiation is not a CSRF-sensitive state change
  # (the OAuth `state` param protects the callback). Using GET also avoids
  # reverse-proxy/session edge cases that were 422'ing browser POSTs on boxd.
  get "login", to: "sessions#new"
  get "login/start", to: "sessions#create"
  post "login", to: "sessions#create"
  match "auth/callback", to: "sessions#callback", via: %i[get post]
  match "logout", to: "sessions#destroy", via: %i[get post]
  get ".well-known/oauth-client-metadata", to: "sessions#client_metadata"
end
