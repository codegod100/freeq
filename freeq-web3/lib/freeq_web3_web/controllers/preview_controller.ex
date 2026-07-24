defmodule FreeqWeb3Web.PreviewController do
  @moduledoc "Serve locally cached link-preview images (same-origin)."
  use FreeqWeb3Web, :controller

  alias FreeqWeb3.LinkPreview

  def show(conn, %{"id" => id}) do
    case LinkPreview.read_image(id) do
      {bin, content_type} ->
        conn
        |> put_resp_header("cache-control", "public, max-age=604800, immutable")
        |> put_resp_content_type(content_type)
        |> send_resp(200, bin)

      nil ->
        send_resp(conn, 404, "not found")
    end
  end
end
