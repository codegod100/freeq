defmodule FreeqWeb3.PendingOauthStore do
  @moduledoc """
  Short-lived disk store for in-flight AT Protocol OAuth logins.

  Keyed by the OAuth `state` parameter so `/auth/callback` can recover the
  PKCE verifier + DPoP key even when the browser drops cookies after the
  cross-site PDS redirect. Files expire after TTL and are deleted on take.
  """

  require Logger

  @ttl_seconds 30 * 60

  @doc "Save a prepared-login payload map (string keys). Returns state."
  def save(state, payload) when is_binary(state) and is_map(payload) do
    if state == "" do
      raise ArgumentError, "empty state"
    end

    data =
      payload
      |> Map.put("state", state)
      |> Map.put("created_at", System.system_time(:second))

    path = path_for(state)
    File.mkdir_p!(Path.dirname(path))
    atomic_write!(path, Jason.encode!(data))
    state
  end

  @doc "Load without deleting. Returns map or nil."
  def load(state) when is_binary(state) do
    if state == "" do
      nil
    else
      path = path_for(state)

      with true <- File.exists?(path),
           {:ok, raw} <- File.read(path),
           {:ok, data} <- Jason.decode(raw),
           false <- expired?(data) do
        data
      else
        true ->
          # expired
          _ = File.rm(path_for(state))
          nil

        _ ->
          nil
      end
    end
  rescue
    e ->
      Logger.warning("load pending oauth failed: #{Exception.message(e)}")
      nil
  end

  @doc "Load and delete (one-shot). Returns map or nil."
  def take(state) when is_binary(state) do
    data = load(state)
    remove(state)
    data
  end

  def remove(state) when is_binary(state) do
    if state != "" do
      path = path_for(state)
      if File.exists?(path), do: File.rm(path)
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc "Drop expired files (best-effort)."
  def gc! do
    dir = store_dir()

    if File.dir?(dir) do
      for path <- Path.wildcard(Path.join(dir, "*.json")) do
        with {:ok, raw} <- File.read(path),
             {:ok, data} <- Jason.decode(raw),
             true <- expired?(data) do
          File.rm(path)
        end
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  defp store_dir do
    raw =
      Application.get_env(
        :freeq_web3,
        :pending_oauth_dir,
        System.get_env("FREEQ_WEB3_PENDING_OAUTH_DIR", ".dev-data/web3-pending-oauth")
      )

    if Path.type(raw) == :absolute do
      raw
    else
      Path.expand(raw)
    end
  end

  defp path_for(state) do
    safe = String.replace(state, ~r/[^A-Za-z0-9_\-]/, "_")
    Path.join(store_dir(), "#{safe}.json")
  end

  defp expired?(data) do
    created = data["created_at"] || 0
    created <= 0 or System.system_time(:second) - created > @ttl_seconds
  end

  defp atomic_write!(path, text) do
    tmp = path <> ".#{System.unique_integer([:positive])}.tmp"
    File.write!(tmp, text)
    File.chmod!(tmp, 0o600)
    File.rename!(tmp, path)
    File.chmod!(path, 0o600)
  after
    # best-effort cleanup if rename failed mid-way
    :ok
  end
end
