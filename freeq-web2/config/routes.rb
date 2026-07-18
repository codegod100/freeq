Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  root to: redirect("/chat", status: 302)

  resources :chat, only: %i[index], path: "chat"
  get "chat/:channel", to: "chat#show", as: :chat_channel

  # Mutations used by the JS reaction picker (and available as plain POST APIs).
  # Send/join/part also go through StimulusReflex; these routes mirror freeq-webui.
  post "chat/:channel/react", to: "chat#react"
  post "chat/:channel/unreact", to: "chat#unreact"
end