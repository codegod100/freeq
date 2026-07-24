defmodule FreeqWeb3Web.PageControllerTest do
  use FreeqWeb3Web.ConnCase

  test "GET /up", %{conn: conn} do
    conn = get(conn, ~p"/up")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end
end
