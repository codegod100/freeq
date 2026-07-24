defmodule FreeqWeb3Web.ApiOgTest do
  use FreeqWeb3Web.ConnCase, async: true

  test "GET /api/v1/og without url returns 400", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/og")
    assert json_response(conn, 400)["error"] =~ "url"
  end

  test "GET /api/v1/og rejects non-http urls", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/og?url=#{URI.encode_www_form("ftp://example.com")}")
    assert json_response(conn, 400)["error"] =~ "Invalid"
  end

  test "GET /api/v1/og rejects empty url after trim", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/og?url=")
    assert json_response(conn, 400)["error"] =~ "url"
  end
end
