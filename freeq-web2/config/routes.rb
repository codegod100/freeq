Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  root to: redirect("/chat", status: 302)

  resources :chat, only: %i[index], path: "chat"
  get "chat/:channel", to: "chat#show", as: :chat_channel
  get "chat/dm/:nick", to: "chat#dm", as: :chat_dm
  # Mutations used by the JS reaction picker (and available as plain POST APIs).
  post "chat/:channel/react", to: "chat#react"
  post "chat/:channel/unreact", to: "chat#unreact"

  # Channel policy info.
  get "api/policy/:channel", to: "api#policy"

  # AT Protocol OAuth.
  get "login", to: "sessions#new"
  post "login", to: "sessions#create"
  get "auth/callback", to: "sessions#callback"
  post "logout", to: "sessions#destroy"
  get ".well-known/oauth-client-metadata", to: "sessions#client_metadata"
end