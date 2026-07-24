defmodule FreeqWeb3Web.ChatIndexLiveTest do
  use FreeqWeb3Web.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders channel list shell via ChatLive :index", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/chat")
    assert html =~ "freeq"
    assert html =~ "channels"
    assert html =~ "join #channel"
  end

  test "root serves channel list (same LiveView as /chat)", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "channels"
  end

  test "patch from channel to /chat keeps the same LiveView process", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/chat/freeq")
    pid = view.pid
    # Live patch to directory — same process (AV would leave on remount).
    html = render_patch(view, ~p"/chat")
    assert view.pid == pid
    assert html =~ "join #channel"
    assert html =~ "channels"
  end
end
