defmodule FreeqWeb3Web.PreviewControllerTest do
  # Not async: tests share Application env for preview_cache_dir.
  use FreeqWeb3Web.ConnCase, async: false

  alias FreeqWeb3.LinkPreview

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "web3-preview-ctrl-#{System.unique_integer([:positive])}"
      )

    prev = Application.get_env(:freeq_web3, :preview_cache_dir)
    Application.put_env(:freeq_web3, :preview_cache_dir, dir)
    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf(dir)
      if prev, do: Application.put_env(:freeq_web3, :preview_cache_dir, prev)
    end)

    {:ok, dir: dir}
  end

  test "serves a cached image", %{conn: conn, dir: dir} do
    id = "abcdef0123456789abcdef0123456789.jpg"
    File.write!(Path.join(dir, id), <<0xFF, 0xD8, 0xFF, 0xD9, "jpeg-bytes">>)

    conn = get(conn, ~p"/preview-cache/#{id}")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/jpeg"
    assert conn.resp_body =~ "jpeg-bytes"
  end

  test "404 for missing id", %{conn: conn} do
    conn = get(conn, ~p"/preview-cache/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.jpg")
    assert conn.status == 404
  end

  test "404 for invalid id", %{conn: conn} do
    conn = get(conn, "/preview-cache/not_valid_id.jpg")
    assert conn.status == 404
  end

  test "LinkPreview.read_image matches controller path", %{dir: dir} do
    id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.png"
    File.write!(Path.join(dir, id), "pngdata")
    assert {"pngdata", "image/png"} = LinkPreview.read_image(id)
  end
end
