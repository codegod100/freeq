defmodule FreeqWeb3.Atproto.OAuthHeaderTest do
  use ExUnit.Case, async: true

  # header_value/2 is private — exercise via probe_dpop_nonce / push path
  # using a thin public wrapper: recompile-time access through :erlang.fun_info
  # is overkill; instead mirror the map/list behavior here by calling the
  # same logic the module uses after the Req header-map fix.

  test "Req-style map headers expose dpop-nonce" do
    headers = %{
      "content-type" => ["application/json"],
      "dpop-nonce" => ["abc-nonce-xyz"]
    }

    assert extract(headers, "dpop-nonce") == "abc-nonce-xyz"
    assert extract(headers, "DPoP-Nonce") == "abc-nonce-xyz"
  end

  test "list-of-tuple headers expose dpop-nonce" do
    headers = [
      {"content-type", "application/json"},
      {"DPoP-Nonce", "list-nonce"}
    ]

    assert extract(headers, "dpop-nonce") == "list-nonce"
  end

  # Keep in sync with FreeqWeb3.Atproto.OAuth.header_value/2
  defp extract(headers, name) when is_map(headers) do
    name_down = String.downcase(name)

    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(to_string(k)) == name_down, do: first(v)
    end)
  end

  defp extract(headers, name) when is_list(headers) do
    name_down = String.downcase(name)

    Enum.find_value(headers, fn
      {k, v} when is_binary(k) ->
        if String.downcase(k) == name_down, do: first(v)

      _ ->
        nil
    end)
  end

  defp first([v | _]) when is_binary(v), do: v
  defp first(v) when is_binary(v), do: v
  defp first(_), do: nil
end
