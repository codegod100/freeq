defmodule FreeqWeb3Web.ChatIndexLiveTest do
  use FreeqWeb3Web.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders channel list shell", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/chat")
    assert html =~ "freeq"
    assert html =~ "channels"
    assert html =~ "join #channel"
  end

  test "root redirects into chat live session", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "channels"
  end
end
