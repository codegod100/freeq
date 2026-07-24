defmodule FreeqWeb3.SessionStore do
  @moduledoc """
  Disk-backed encrypted OAuth session store.

  Mirrors freeq-web2 `SessionStore` / freeq-webui:
  - one file per browser `session_id` under a local directory
  - AES-256-GCM with a per-session key derived via HKDF-SHA256 from a
    machine-local secret + the session_id
  - file format: nonce (12) || ciphertext || tag (16)

  Env: `FREEQ_WEB3_SESSIONS_DIR` — default `.dev-data/web3-sessions`.
  Set empty to disable disk persistence.
  """

  require Logger

  alias FreeqWeb3.Atproto.OAuthSession

  @info "freeq-session-encryption"
  @nonce_len 12
  @tag_len 16
  @key_len 32

  defstruct [:dir, :machine_key]

  @type t :: %__MODULE__{dir: String.t(), machine_key: binary()}

  @doc """
  Open or create the store. Returns `nil` when persistence is disabled
  (empty dir config) or initialization fails.
  """
  def open do
    raw =
      Application.get_env(
        :freeq_web3,
        :sessions_dir,
        System.get_env("FREEQ_WEB3_SESSIONS_DIR", ".dev-data/web3-sessions")
      )

    if raw in [nil, ""] do
      nil
    else
      dir = expand_dir(raw)
      File.mkdir_p!(dir)
      machine_key = load_or_create_machine_key(dir)
      %__MODULE__{dir: dir, machine_key: machine_key}
    end
  rescue
    e ->
      Logger.warning("session store init failed: #{Exception.message(e)}")
      nil
  end

  @doc "Save OAuth credentials for `session_id`. No-op when store disabled."
  def save(sid, %OAuthSession{} = oauth) when is_binary(sid) do
    if sid == "" do
      :ok
    else
      with %__MODULE__{} = store <- open_cached() do
        path = session_path(store, sid)
        key = derive_key(store, sid)
        plaintext = Jason.encode!(OAuthSession.to_map(oauth))
        blob = encrypt(plaintext, key)
        atomic_write!(path, blob)
      end

      :ok
    end
  rescue
    e ->
      Logger.warning("save session #{short(sid)} failed: #{Exception.message(e)}")
      :ok
  end

  def save(_, _), do: :ok

  @doc "Load OAuth credentials. Returns `%OAuthSession{}` or `nil`."
  def load(sid) when is_binary(sid) do
    if sid == "" do
      nil
    else
      with %__MODULE__{} = store <- open_cached(),
           path = session_path(store, sid),
           true <- File.exists?(path),
           key = derive_key(store, sid),
           {:ok, raw} <- File.read(path),
           plaintext when is_binary(plaintext) <- decrypt(raw, key),
           {:ok, data} <- Jason.decode(plaintext) do
        OAuthSession.from_map(data)
      else
        _ -> nil
      end
    end
  rescue
    e ->
      Logger.warning("load session #{short(sid)} failed: #{Exception.message(e)}")
      nil
  end

  def load(_), do: nil

  @doc "Drop persisted OAuth + channel list for logout."
  def remove(sid) when is_binary(sid) do
    if sid != "" do
      with %__MODULE__{} = store <- open_cached() do
        path = session_path(store, sid)
        ch_path = channels_path(store, sid)
        if File.exists?(path), do: File.rm(path)
        if File.exists?(ch_path), do: File.rm(ch_path)
      end
    end

    :ok
  rescue
    e ->
      Logger.warning("remove session #{short(sid)} failed: #{Exception.message(e)}")
      :ok
  end

  def remove(_), do: :ok

  @doc "Persist client-authoritative channel list."
  def save_channels(sid, channels) when is_binary(sid) and is_list(channels) do
    if sid == "" do
      :ok
    else
      with %__MODULE__{} = store <- open_cached() do
        key = derive_key(store, sid)
        plaintext = Jason.encode!(Enum.map(channels, &to_string/1))
        atomic_write!(channels_path(store, sid), encrypt(plaintext, key))
      end

      :ok
    end
  rescue
    e ->
      Logger.warning("save channels #{short(sid)} failed: #{Exception.message(e)}")
      :ok
  end

  def save_channels(_, _), do: :ok

  @doc "Load channel list. Returns a list of channel name strings."
  def load_channels(sid) when is_binary(sid) do
    if sid == "" do
      []
    else
      with %__MODULE__{} = store <- open_cached(),
           path = channels_path(store, sid),
           true <- File.exists?(path),
           key = derive_key(store, sid),
           {:ok, raw} <- File.read(path),
           plaintext when is_binary(plaintext) <- decrypt(raw, key),
           {:ok, data} when is_list(data) <- Jason.decode(plaintext) do
        Enum.map(data, &to_string/1)
      else
        _ -> []
      end
    end
  rescue
    e ->
      Logger.warning("load channels #{short(sid)} failed: #{Exception.message(e)}")
      []
  end

  def load_channels(_), do: []

  # ── internals ──────────────────────────────────────────────────────────

  # Cache the opened store in the process dictionary for hot paths
  # (set_auth, channel join). Machine key is stable for process lifetime.
  defp open_cached do
    case Process.get({__MODULE__, :store}) do
      :disabled ->
        nil

      %__MODULE__{} = store ->
        store

      nil ->
        case open() do
          nil ->
            Process.put({__MODULE__, :store}, :disabled)
            nil

          store ->
            Process.put({__MODULE__, :store}, store)
            store
        end
    end
  end

  defp expand_dir(raw) do
    if Path.type(raw) == :absolute, do: raw, else: Path.expand(raw)
  end

  defp session_path(%__MODULE__{dir: dir}, sid) do
    Path.join(dir, "#{safe_sid(sid)}.bin")
  end

  defp channels_path(%__MODULE__{dir: dir}, sid) do
    Path.join(dir, "#{safe_sid(sid)}.channels")
  end

  defp safe_sid(sid) do
    String.replace(sid, ~r{[/\\.]}, "_")
  end

  defp load_or_create_machine_key(dir) do
    key_path = Path.join(dir, ".key")

    if File.exists?(key_path) do
      bytes = File.read!(key_path)

      if byte_size(bytes) != @key_len do
        raise "session key file has wrong length: #{byte_size(bytes)}"
      end

      bytes
    else
      key = :crypto.strong_rand_bytes(@key_len)
      atomic_write!(key_path, key)
      key
    end
  end

  # HKDF-SHA256(ikm=machine_key, salt=sid, info="freeq-session-encryption") → 32B
  # Matches freeq-web2 / freeq_sdk::oauth::derive_session_key.
  defp derive_key(%__MODULE__{machine_key: machine_key}, sid) do
    hkdf_sha256(machine_key, to_string(sid), @info, @key_len)
  end

  # RFC 5869 HKDF with HMAC-SHA256 (extract + expand). OTP does not always
  # expose :crypto.hkdf/5 depending on the Erlang build.
  defp hkdf_sha256(ikm, salt, info, length)
       when is_binary(ikm) and is_binary(salt) and is_binary(info) and is_integer(length) do
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    hash_len = 32
    n = div(length + hash_len - 1, hash_len)

    {okm, _} =
      Enum.reduce(1..n, {<<>>, <<>>}, fn i, {acc, prev} ->
        t = :crypto.mac(:hmac, :sha256, prk, prev <> info <> <<i>>)
        {acc <> t, t}
      end)

    binary_part(okm, 0, length)
  end

  defp encrypt(plaintext, key) when is_binary(plaintext) and is_binary(key) do
    nonce = :crypto.strong_rand_bytes(@nonce_len)
    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, "", @tag_len, true)

    if byte_size(tag) != @tag_len do
      raise "unexpected GCM tag length #{byte_size(tag)}"
    end

    nonce <> ciphertext <> tag
  end

  defp decrypt(data, key) when is_binary(data) and is_binary(key) do
    if byte_size(data) < @nonce_len + @tag_len do
      raise "encrypted session file too short"
    end

    nonce = binary_part(data, 0, @nonce_len)
    tag = binary_part(data, byte_size(data) - @tag_len, @tag_len)
    ciphertext = binary_part(data, @nonce_len, byte_size(data) - @nonce_len - @tag_len)

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, "", tag, false) do
      plaintext when is_binary(plaintext) -> plaintext
      :error -> raise "session decrypt failed"
    end
  end

  defp atomic_write!(path, bytes) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".#{System.unique_integer([:positive])}.tmp"
    File.write!(tmp, bytes)
    File.chmod!(tmp, 0o600)
    File.rename!(tmp, path)
    File.chmod!(path, 0o600)
  end

  defp short(sid) when is_binary(sid), do: String.slice(sid, 0, 8)
  defp short(_), do: "?"
end
