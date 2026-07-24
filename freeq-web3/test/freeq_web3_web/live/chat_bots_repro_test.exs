defmodule FreeqWeb3Web.ChatBotsReproTest do
  use FreeqWeb3Web.ConnCase, async: false
  import Phoenix.LiveViewTest

  test "opens #bots without crash", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/chat/bots")
    assert html =~ "bots" or html =~ "#bots"
  end

  test "opens #freeq without crash", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/chat/freeq")
    assert html =~ "freeq"
  end
end
