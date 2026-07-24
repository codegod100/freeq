defmodule FreeqWeb3.PendingOauthStoreTest do
  use ExUnit.Case, async: true

  alias FreeqWeb3.PendingOauthStore

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "web3-pending-oauth-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:freeq_web3, :pending_oauth_dir, dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  test "save, load, take, remove" do
    state = "state_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
    payload = %{"code_verifier" => "cv", "handle" => "alice.bsky.social"}

    assert PendingOauthStore.save(state, payload) == state
    loaded = PendingOauthStore.load(state)
    assert loaded["code_verifier"] == "cv"
    assert loaded["handle"] == "alice.bsky.social"
    assert loaded["state"] == state

    taken = PendingOauthStore.take(state)
    assert taken["code_verifier"] == "cv"
    assert PendingOauthStore.load(state) == nil
  end
end
