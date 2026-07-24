defmodule FreeqWeb3.Atproto.DpopKey do
  @moduledoc """
  Ed25519 keypair for DPoP (Demonstrating Proof-of-Possession) proofs.

  Mirrors freeq-web2 `Atproto::DpopKey` / freeq-sdk DPoP.
  """

  defstruct [:private_key, :public_key]

  @type t :: %__MODULE__{
          private_key: binary(),
          public_key: binary()
        }

  @doc "Generate a fresh Ed25519 keypair."
  def generate do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    %__MODULE__{private_key: private_key, public_key: public_key}
  end

  @doc "Restore from raw 32-byte private seed (base64url or binary)."
  def deserialize(str) when is_binary(str) do
    private_key =
      case Base.url_decode64(str, padding: false) do
        {:ok, bytes} when byte_size(bytes) == 32 ->
          bytes

        _ ->
          # Already raw bytes?
          if byte_size(str) == 32, do: str, else: raise(ArgumentError, "invalid dpop_key")
      end

    {public_key, _} = :crypto.generate_key(:eddsa, :ed25519, private_key)
    %__MODULE__{private_key: private_key, public_key: public_key}
  end

  @doc "Serialize private seed as unpadded base64url."
  def serialize(%__MODULE__{private_key: private_key}) do
    Base.url_encode64(private_key, padding: false)
  end

  @doc "JWK representation for the DPoP JWT header."
  def jwk(%__MODULE__{public_key: public_key}) do
    %{
      "kty" => "OKP",
      "crv" => "Ed25519",
      "x" => Base.url_encode64(public_key, padding: false)
    }
  end

  @doc """
  Build a DPoP proof JWT for the given HTTP method and URL.

  Options:
  - `:nonce` — DPoP nonce from the resource server
  - `:access_token` — when set, includes `ath` (SHA-256 of token, base64url)
  """
  def proof(%__MODULE__{} = key, method, url, opts \\ []) do
    method = method |> to_string() |> String.upcase()
    nonce = Keyword.get(opts, :nonce)
    access_token = Keyword.get(opts, :access_token)

    header = %{
      "typ" => "dpop+jwt",
      "alg" => "EdDSA",
      "jwk" => jwk(key)
    }

    payload =
      %{
        "htm" => method,
        "htu" => url,
        "iat" => System.system_time(:second),
        "jti" => Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      }
      |> maybe_put("nonce", nonce)
      |> maybe_put_ath(access_token)

    header_b64 = b64url_json(header)
    payload_b64 = b64url_json(payload)
    signing_input = header_b64 <> "." <> payload_b64

    signature =
      :crypto.sign(:eddsa, :none, signing_input, [key.private_key, :ed25519])

    signing_input <> "." <> Base.url_encode64(signature, padding: false)
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, _k, ""), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  defp maybe_put_ath(map, nil), do: map
  defp maybe_put_ath(map, ""), do: map

  defp maybe_put_ath(map, token) do
    ath = :crypto.hash(:sha256, token) |> Base.url_encode64(padding: false)
    Map.put(map, "ath", ath)
  end

  defp b64url_json(map) do
    map
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end
end
