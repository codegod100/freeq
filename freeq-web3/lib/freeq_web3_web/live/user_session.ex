defmodule FreeqWeb3Web.Live.UserSession do
  @moduledoc """
  LiveView on_mount: read `freeq_session` from the Plug session and start
  the Session GenServer. The id itself is minted by
  `FreeqWeb3Web.Plugs.SessionId` in the browser pipeline.
  """

  import Phoenix.Component

  alias FreeqWeb3.Session

  def on_mount(:default, _params, session, socket) do
    sid =
      case session do
        %{"freeq_session" => id} when is_binary(id) and id != "" -> id
        _ -> new_session_id()
      end

    {:ok, _} = Session.get_or_start(sid)
    {:cont, assign(socket, :freeq_session, sid)}
  end

  defp new_session_id do
    # Fallback if the plug did not run (e.g. tests without the pipeline).
    Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end
end
