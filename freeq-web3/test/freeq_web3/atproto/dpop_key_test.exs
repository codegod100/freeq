defmodule FreeqWeb3.Atproto.DpopKeyTest do
  use ExUnit.Case, async: true

  alias FreeqWeb3.Atproto.DpopKey

  test "generate, serialize, deserialize round-trip" do
    key = DpopKey.generate()
    assert byte_size(key.private_key) == 32
    assert byte_size(key.public_key) == 32

    ser = DpopKey.serialize(key)
    key2 = DpopKey.deserialize(ser)
    assert key2.private_key == key.private_key
    assert key2.public_key == key.public_key
  end

  test "proof is a three-part JWT with EdDSA header" do
    key = DpopKey.generate()
    proof = DpopKey.proof(key, "POST", "https://example.com/token")

    parts = String.split(proof, ".")
    assert length(parts) == 3

    {:ok, header_json} = Base.url_decode64(Enum.at(parts, 0), padding: false)
    header = Jason.decode!(header_json)
    assert header["typ"] == "dpop+jwt"
    assert header["alg"] == "EdDSA"
    assert header["jwk"]["crv"] == "Ed25519"
    assert header["jwk"]["kty"] == "OKP"
  end

  test "proof includes ath when access_token is set" do
    key = DpopKey.generate()
    proof = DpopKey.proof(key, "GET", "https://pds.example/xrpc/foo", access_token: "tok")
    parts = String.split(proof, ".")
    {:ok, payload_json} = Base.url_decode64(Enum.at(parts, 1), padding: false)
    payload = Jason.decode!(payload_json)
    assert is_binary(payload["ath"])
    assert payload["ath"] != ""
  end

  test "proof includes nonce when provided" do
    key = DpopKey.generate()
    proof = DpopKey.proof(key, "POST", "https://example.com/par", nonce: "abc123")
    parts = String.split(proof, ".")
    {:ok, payload_json} = Base.url_decode64(Enum.at(parts, 1), padding: false)
    payload = Jason.decode!(payload_json)
    assert payload["nonce"] == "abc123"
  end
end
