defmodule FreeqWeb3Web.PageController do
  use FreeqWeb3Web, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/chat")
  end

  def up(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
