defmodule FreeqWeb3.Atproto.OAuthSession do
  @moduledoc """
  Authenticated AT Protocol session. Carried by `Session.Server` for SASL.

  Mirrors freeq-web2 `Atproto::OAuthSession`.
  """

  alias FreeqWeb3.Atproto.DpopKey
  alias FreeqWeb3.Irc.Render

  @enforce_keys [:did, :handle, :access_token, :pds_url, :dpop_key]
  defstruct [
    :did,
    :handle,
    :access_token,
    :pds_url,
    :dpop_key,
    :dpop_nonce,
    :refresh_token,
    :token_endpoint,
    :client_id
  ]

  @type t :: %__MODULE__{
          did: String.t(),
          handle: String.t(),
          access_token: String.t(),
          pds_url: String.t(),
          dpop_key: DpopKey.t(),
          dpop_nonce: String.t() | nil,
          refresh_token: String.t() | nil,
          token_endpoint: String.t() | nil,
          client_id: String.t() | nil
        }

  def nick(%__MODULE__{handle: handle}), do: Render.sanitize_nick(handle)

  def to_map(%__MODULE__{} = s) do
    %{
      "did" => s.did,
      "handle" => s.handle,
      "access_token" => s.access_token,
      "pds_url" => s.pds_url,
      "dpop_key" => DpopKey.serialize(s.dpop_key),
      "dpop_nonce" => s.dpop_nonce,
      "refresh_token" => s.refresh_token,
      "token_endpoint" => s.token_endpoint,
      "client_id" => s.client_id
    }
  end

  def from_map(h) when is_map(h) do
    h = stringify_keys(h)

    key =
      case h["dpop_key"] do
        %DpopKey{} = k -> k
        raw when is_binary(raw) and raw != "" -> DpopKey.deserialize(raw)
        _ -> raise ArgumentError, "missing dpop_key"
      end

    %__MODULE__{
      did: h["did"],
      handle: h["handle"],
      access_token: h["access_token"],
      pds_url: h["pds_url"],
      dpop_key: key,
      dpop_nonce: h["dpop_nonce"],
      refresh_token: h["refresh_token"],
      token_endpoint: h["token_endpoint"],
      client_id: h["client_id"]
    }
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
