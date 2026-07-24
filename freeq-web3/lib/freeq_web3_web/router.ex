defmodule FreeqWeb3Web.Router do
  use FreeqWeb3Web, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug FreeqWeb3Web.Plugs.SessionId
    plug :fetch_live_flash
    plug :put_root_layout, html: {FreeqWeb3Web.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  # Session cookie only — no CSRF. Used for same-origin GET JSON and for
  # proxying JS modules (Plug.CSRFProtection rejects application/javascript
  # GETs without X-Requested-With as "cross-origin embed").
  pipeline :browser_api do
    plug :accepts, ["json", "javascript", "html", "*/*"]
    plug :fetch_session
    plug FreeqWeb3Web.Plugs.SessionId
    plug :put_secure_browser_headers
  end

  # Same-origin JSON POSTs that need the CSRF token (call control).
  pipeline :browser_api_csrf do
    plug :accepts, ["json"]
    plug :fetch_session
    plug FreeqWeb3Web.Plugs.SessionId
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", FreeqWeb3Web do
    pipe_through :browser

    get "/up", PageController, :up

    # AT Protocol OAuth (port of freeq-web2 sessions).
    get "/login", SessionsController, :new
    get "/login/start", SessionsController, :create
    post "/login", SessionsController, :create
    get "/auth/callback", SessionsController, :callback
    post "/auth/callback", SessionsController, :callback
    get "/logout", SessionsController, :destroy
    post "/logout", SessionsController, :destroy
    get "/.well-known/oauth-client-metadata", SessionsController, :client_metadata

    live_session :chat, on_mount: [FreeqWeb3Web.Live.UserSession] do
      live "/", ChatIndexLive, :index
      live "/chat", ChatIndexLive, :index
      live "/chat/:channel", ChatLive, :show
    end
  end

  scope "/", FreeqWeb3Web do
    pipe_through :browser_api_csrf

    post "/api/av/start", ApiController, :av_start
    post "/api/av/join", ApiController, :av_join
    post "/api/av/leave", ApiController, :av_leave
    post "/api/av/end", ApiController, :av_end
  end

  scope "/", FreeqWeb3Web do
    pipe_through :browser_api

    get "/api/v1/channels/:channel/sessions", ApiController, :channel_sessions
    get "/api/v1/sessions/:id", ApiController, :session_detail
    get "/api/v1/av/sessions/:id/token", ApiController, :av_token
    get "/api/v1/og", ApiController, :og_preview
    get "/preview-cache/:id", PreviewController, :show
    # MoQ publish/watch JS modules — must not go through protect_from_forgery.
    get "/av/assets/*path", ApiController, :av_asset
  end
end
