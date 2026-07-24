defmodule FreeqWeb3Web.SessionsControllerTest do
  use FreeqWeb3Web.ConnCase, async: true

  test "GET /login renders sign-in form", %{conn: conn} do
    conn = get(conn, ~p"/login")
    assert html_response(conn, 200) =~ "Sign in to freeq"
    assert html_response(conn, 200) =~ "you.bsky.social"
    assert html_response(conn, 200) =~ "Continue as guest"
  end

  test "GET /login/start without handle redirects", %{conn: conn} do
    conn = get(conn, ~p"/login/start")
    assert redirected_to(conn) == ~p"/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Handle is required"
  end

  test "GET /.well-known/oauth-client-metadata returns JSON", %{conn: conn} do
    conn = get(conn, ~p"/.well-known/oauth-client-metadata")

    assert %{"client_name" => "freeq-web3", "dpop_bound_access_tokens" => true} =
             json_response(conn, 200)

    assert json_response(conn, 200)["scope"] == "atproto transition:generic"
    assert is_list(json_response(conn, 200)["redirect_uris"])
  end

  test "GET /.well-known/oauth-client-metadata accepts application/json", %{conn: conn} do
    # Authorization servers (PAR) fetch with Accept: application/json only —
    # must not 406 via the html-only :browser pipeline.
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> get(~p"/.well-known/oauth-client-metadata")

    assert json_response(conn, 200)["client_name"] == "freeq-web3"
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
  end

  test "GET /logout redirects to chat", %{conn: conn} do
    conn = get(conn, ~p"/logout")
    assert redirected_to(conn) == ~p"/chat"
  end
end
