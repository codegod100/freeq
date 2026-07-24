defmodule FreeqWeb3.Atproto.SaslTest do
  use ExUnit.Case, async: true

  alias FreeqWeb3.Atproto.DpopKey
  alias FreeqWeb3.Atproto.OAuthSession
  alias FreeqWeb3.Atproto.Sasl

  test "parse_challenge decodes base64url JSON" do
    payload = %{
      "session_id" => "sid-1",
      "nonce" => "n-abc",
      "timestamp" => 1_700_000_000
    }

    b64 = payload |> Jason.encode!() |> Base.url_encode64(padding: false)
    ch = Sasl.parse_challenge(b64)
    assert ch.session_id == "sid-1"
    assert ch.nonce == "n-abc"
    assert ch.timestamp == 1_700_000_000
  end

  test "build_response is base64url JSON with pds-oauth method" do
    oauth = %OAuthSession{
      did: "did:plc:test",
      handle: "alice.bsky.social",
      access_token: "access-tok",
      pds_url: "https://pds.example",
      dpop_key: DpopKey.generate(),
      dpop_nonce: "nonce-1"
    }

    resp = Sasl.build_response("challenge-nonce", oauth)
    {:ok, json} = Base.url_decode64(resp, padding: false)
    data = Jason.decode!(json)

    assert data["did"] == "did:plc:test"
    assert data["signature"] == "access-tok"
    assert data["method"] == "pds-oauth"
    assert data["pds_url"] == "https://pds.example"
    assert data["challenge_nonce"] == "challenge-nonce"
    assert is_binary(data["dpop_proof"])
    assert length(String.split(data["dpop_proof"], ".")) == 3
  end
end
