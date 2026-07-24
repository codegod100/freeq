defmodule FreeqWeb3.Atproto.Sasl do
  @moduledoc """
  SASL ATPROTO-CHALLENGE response builder.

  Given a server challenge (base64url JSON) and an `OAuthSession`, builds
  the base64url-encoded response payload for `AUTHENTICATE`.
  """

  alias FreeqWeb3.Atproto.DpopKey
  alias FreeqWeb3.Atproto.OAuthSession

  @doc """
  Parse the server's AUTHENTICATE challenge (base64url JSON).

  Returns `%{session_id: _, nonce: _, timestamp: _}`.
  """
  def parse_challenge(challenge_b64) when is_binary(challenge_b64) do
    json =
      case Base.url_decode64(challenge_b64, padding: false) do
        {:ok, bin} -> bin
        :error -> Base.decode64!(challenge_b64)
      end

    data = Jason.decode!(json)

    %{
      session_id: data["session_id"],
      nonce: data["nonce"],
      timestamp: data["timestamp"]
    }
  end

  @doc """
  Build the SASL response payload for the given challenge nonce + OAuth session.

  The DPoP proof is for GET `/xrpc/com.atproto.server.getSession` on the PDS.
  """
  def build_response(challenge_nonce, %OAuthSession{} = oauth) do
    get_session_url =
      String.trim_trailing(oauth.pds_url, "/") <> "/xrpc/com.atproto.server.getSession"

    dpop_proof =
      DpopKey.proof(oauth.dpop_key, "GET", get_session_url,
        nonce: oauth.dpop_nonce,
        access_token: oauth.access_token
      )

    payload = %{
      "did" => oauth.did,
      "signature" => oauth.access_token,
      "method" => "pds-oauth",
      "pds_url" => oauth.pds_url,
      "dpop_proof" => dpop_proof,
      "challenge_nonce" => challenge_nonce
    }

    payload
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end
end
