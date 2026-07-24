defmodule FreeqWeb3.SessionStoreTest do
  use ExUnit.Case, async: true

  alias FreeqWeb3.Atproto.DpopKey
  alias FreeqWeb3.Atproto.OAuthSession
  alias FreeqWeb3.SessionStore

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "web3-sessions-test-#{System.unique_integer([:positive])}"
      )

    # Clear process-local store cache so each test opens against its own dir.
    Process.delete({SessionStore, :store})
    Application.put_env(:freeq_web3, :sessions_dir, dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp sample_oauth do
    key = DpopKey.generate()

    %OAuthSession{
      did: "did:plc:testuser",
      handle: "alice.bsky.social",
      access_token: "access-token-xyz",
      pds_url: "https://pds.example",
      dpop_key: key,
      dpop_nonce: "nonce1",
      refresh_token: "refresh-token-abc",
      token_endpoint: "https://auth.example/token",
      client_id: "https://app.example/client"
    }
  end

  test "save, load, remove oauth credentials" do
    sid = "sess_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
    oauth = sample_oauth()

    assert SessionStore.load(sid) == nil
    assert :ok = SessionStore.save(sid, oauth)

    loaded = SessionStore.load(sid)
    assert %OAuthSession{} = loaded
    assert loaded.did == oauth.did
    assert loaded.handle == oauth.handle
    assert loaded.access_token == oauth.access_token
    assert loaded.pds_url == oauth.pds_url
    assert loaded.refresh_token == oauth.refresh_token
    assert loaded.token_endpoint == oauth.token_endpoint
    assert loaded.client_id == oauth.client_id
    assert loaded.dpop_nonce == oauth.dpop_nonce
    assert DpopKey.serialize(loaded.dpop_key) == DpopKey.serialize(oauth.dpop_key)

    assert :ok = SessionStore.remove(sid)
    assert SessionStore.load(sid) == nil
  end

  test "save and load channel list" do
    sid = "sess_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

    assert SessionStore.load_channels(sid) == []
    assert :ok = SessionStore.save_channels(sid, ["#freeq", "#dev"])
    assert SessionStore.load_channels(sid) == ["#freeq", "#dev"]

    assert :ok = SessionStore.remove(sid)
    assert SessionStore.load_channels(sid) == []
  end

  test "files are not plaintext" do
    sid = "sess_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
    oauth = sample_oauth()
    assert :ok = SessionStore.save(sid, oauth)

    path =
      Path.wildcard(Path.join(Application.get_env(:freeq_web3, :sessions_dir), "*.bin"))
      |> List.first()

    assert is_binary(path)
    raw = File.read!(path)
    refute String.contains?(raw, "access-token-xyz")
    refute String.contains?(raw, "alice.bsky.social")
  end

  test "disabled when sessions_dir is empty" do
    Process.delete({SessionStore, :store})
    Application.put_env(:freeq_web3, :sessions_dir, "")

    oauth = sample_oauth()
    sid = "sess_disabled"
    assert :ok = SessionStore.save(sid, oauth)
    assert SessionStore.load(sid) == nil
  end
end
