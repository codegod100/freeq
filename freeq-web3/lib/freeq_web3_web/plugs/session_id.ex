defmodule FreeqWeb3Web.Plugs.SessionId do
  @moduledoc """
  Ensures every browser has a stable `freeq_session` id in the Plug session
  (cookie-backed). LiveViews read it via `on_mount` session map.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, :freeq_session) do
      id when is_binary(id) and id != "" ->
        assign(conn, :freeq_session, id)

      _ ->
        id = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

        conn
        |> put_session(:freeq_session, id)
        |> assign(:freeq_session, id)
    end
  end
end
