defmodule FreeqWeb3.LinkPreviewTest do
  # Not async: tests share Application env for preview_cache_dir.
  use ExUnit.Case, async: false

  alias FreeqWeb3.LinkPreview

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "web3-preview-test-#{System.unique_integer([:positive])}"
      )

    prev = Application.get_env(:freeq_web3, :preview_cache_dir)
    Application.put_env(:freeq_web3, :preview_cache_dir, dir)

    on_exit(fn ->
      File.rm_rf(dir)
      if prev, do: Application.put_env(:freeq_web3, :preview_cache_dir, prev)
    end)

    {:ok, dir: dir}
  end

  test "non-msg rows are unchanged" do
    row = %{kind: :join, text: "https://example.com", nick: "a"}
    assert LinkPreview.attach(row) == row
  end

  test "attach_cache_only does not network for unknown urls" do
    row = %{
      kind: :msg,
      text: "https://example.com/no-cache-#{System.unique_integer([:positive])}",
      id: "1"
    }

    assert LinkPreview.attach_cache_only(row)[:embed] == nil
  end

  test "read_image rejects path traversal" do
    assert LinkPreview.read_image("../etc/passwd") == nil
    assert LinkPreview.read_image("not-a-hash.jpg") == nil
  end

  test "youtube attach caches a local image path", %{dir: dir} do
    row = %{
      kind: :msg,
      id: "yt1",
      nick: "bob",
      text: "watch https://youtu.be/dQw4w9WgXcQ now",
      time: DateTime.utc_now()
    }

    attached = LinkPreview.attach(row)
    embed = attached[:embed]
    assert embed
    assert embed.kind == :youtube
    assert embed.image_url =~ ~r{^/preview-cache/[a-f0-9]+\.jpe?g$}i

    id = Path.basename(embed.image_url)
    assert {bin, "image/jpeg"} = LinkPreview.read_image(id)
    assert byte_size(bin) > 1000
    assert File.dir?(dir)

    # Cache hit: second resolve stays local
    again = LinkPreview.attach_cache_only(row)
    assert again[:embed].image_url == embed.image_url
  end
end
