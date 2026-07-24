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

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", FreeqWeb3Web do
    pipe_through :browser

    get "/up", PageController, :up

    live_session :chat, on_mount: [FreeqWeb3Web.Live.UserSession] do
      live "/", ChatIndexLive, :index
      live "/chat", ChatIndexLive, :index
      live "/chat/:channel", ChatLive, :show
    end
  end
end
