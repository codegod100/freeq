defmodule FreeqWeb3.LinkPreview do
  @moduledoc """
  Server-side link previews with a local image cache.

  Remote OpenGraph / YouTube / Bluesky images are downloaded into
  `preview_cache_dir` and served as same-origin `/preview-cache/:id`
  URLs so page load never hits third-party hosts for preview media.
  """

  require Logger

  alias FreeqWeb3.Rest

  @bsky_post_re ~r/https?:\/\/bsky\.app\/profile\/([^\/\s]+)\/post\/([a-zA-Z0-9]+)/i
  @yt_re ~r/(?:youtube\.com\/watch\?v=|youtu\.be\/|youtube\.com\/shorts\/)([a-zA-Z0-9_-]{11})/i
  @url_re ~r/https?:\/\/[^\s<>\]\)"'{}|\\^`]+/i
  @image_url_re ~r/\.(?:jpg|jpeg|png|gif|webp)(?:\?|#|$)/i
  @skip_re ~r/\/api\/v1\/|\.(?:m4a|mp3|mp4|mov|webm|ogg|wav|aac)(?:\?|#|$)/i
  @media_re ~r/\/api\/v1\/media\//i
  @bsky_cdn_re ~r/cdn\.bsky\.app\/img\//i

  @type embed :: %{
          required(:kind) => :og | :youtube | :bsky,
          required(:href) => String.t(),
          optional(:title) => String.t() | nil,
          optional(:description) => String.t() | nil,
          optional(:site_name) => String.t() | nil,
          optional(:domain) => String.t() | nil,
          optional(:image_url) => String.t() | nil,
          optional(:video_id) => String.t() | nil,
          optional(:bsky) => map()
        }

  @doc "Attach `:embed` (if any) to a message row. Safe for non-msg rows."
  def attach(%{kind: :msg, text: text} = row) when is_binary(text) do
    case resolve(text) do
      nil -> row
      embed -> Map.put(row, :embed, embed)
    end
  end

  def attach(row), do: row

  @doc """
  Attach embeds to a list of rows. Resolves concurrently (cache-first).

  `max_concurrency` and per-URL timeout keep history mount bounded.
  """
  def attach_many(rows, opts \\ []) when is_list(rows) do
    max_c = Keyword.get(opts, :max_concurrency, 4)
    timeout = Keyword.get(opts, :timeout, 6_000)

    rows
    |> Task.async_stream(&attach/1,
      max_concurrency: max_c,
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(rows)
    |> Enum.map(fn
      {{:ok, row}, _} -> row
      {{:exit, _}, orig} -> attach_cache_only(orig)
    end)
  rescue
    _ -> Enum.map(rows, &attach_cache_only/1)
  end

  @doc "Resolve from disk cache only (no network). Used for fast paths."
  def attach_cache_only(%{kind: :msg, text: text} = row) when is_binary(text) do
    case page_key(text) do
      nil ->
        row

      key ->
        case read_meta(key) do
          nil -> row
          embed -> Map.put(row, :embed, embed)
        end
    end
  end

  def attach_cache_only(row), do: row

  @doc "Resolve first embeddable URL in `text` to an embed map (network + cache)."
  def resolve(text) when is_binary(text) do
    cond do
      m = Regex.run(@bsky_post_re, text) ->
        resolve_bsky(Enum.at(m, 0), Enum.at(m, 1), Enum.at(m, 2))

      m = Regex.run(@yt_re, text) ->
        resolve_youtube(Enum.at(m, 1))

      has_inline_image?(text) ->
        nil

      url = first_embeddable_url(text) ->
        resolve_og(url)

      true ->
        nil
    end
  rescue
    e ->
      Logger.debug("link preview resolve failed: #{Exception.message(e)}")
      nil
  end

  def resolve(_), do: nil

  @doc "Read a cached image by id. Returns `{binary, content_type}` or nil."
  def read_image(id) when is_binary(id) do
    if valid_image_id?(id) do
      path = Path.join(cache_dir(), id)

      if File.exists?(path) do
        case File.read(path) do
          {:ok, bin} -> {bin, content_type_for(id)}
          _ -> nil
        end
      end
    end
  end

  def read_image(_), do: nil

  # ── resolvers ──────────────────────────────────────────────────────────

  defp resolve_youtube(video_id) do
    href = "https://youtube.com/watch?v=#{video_id}"
    key = cache_key("yt:" <> video_id)

    case read_meta(key) do
      %{} = embed ->
        embed

      :fail ->
        nil

      nil ->
        remote = "https://img.youtube.com/vi/#{video_id}/mqdefault.jpg"
        image_url = cache_remote_image(remote)

        embed = %{
          kind: :youtube,
          href: href,
          video_id: video_id,
          title: "YouTube",
          image_url: image_url,
          domain: "youtube.com"
        }

        write_meta(key, embed)
        embed
    end
  end

  defp resolve_bsky(href, handle, rkey) do
    key = cache_key("bsky:#{handle}/#{rkey}")

    case read_meta(key) do
      %{} = embed ->
        embed

      :fail ->
        nil

      nil ->
        uri = "at://#{handle}/app.bsky.feed.post/#{rkey}"

        url =
          "https://public.api.bsky.app/xrpc/app.bsky.feed.getPostThread?uri=#{URI.encode_www_form(uri)}&depth=0"

        case Req.get(url, receive_timeout: 6_000) do
          {:ok, %{status: 200, body: body}} ->
            p = get_in(body, ["thread", "post"]) || %{}
            author = p["author"] || %{}
            record = p["record"] || %{}
            text = record["text"] || ""
            display = author["displayName"] || author["handle"] || handle
            handle_label = author["handle"] || handle

            images =
              get_in(p, ["embed", "images"]) ||
                get_in(p, ["embed", "media", "images"]) ||
                []

            thumbs =
              images
              |> Enum.map(fn img -> img["thumb"] || img["fullsize"] end)
              |> Enum.filter(&(is_binary(&1) and &1 != ""))

            image_url =
              case thumbs do
                [first | _] -> cache_remote_image(first)
                _ -> cache_remote_image(author["avatar"])
              end

            embed = %{
              kind: :bsky,
              href: href,
              title: display,
              description: String.slice(text, 0, 280),
              image_url: image_url,
              domain: "bsky.app",
              bsky: %{
                display: display,
                handle: handle_label,
                text: text,
                likes: p["likeCount"] || 0,
                reposts: p["repostCount"] || 0,
                time: format_bsky_time(record["createdAt"]),
                avatar_url: cache_remote_image(author["avatar"])
              }
            }

            write_meta(key, embed)
            embed

          _ ->
            write_meta(key, %{kind: :bsky, href: href, fail: true})
            nil
        end
    end
  end

  defp resolve_og(url) do
    key = cache_key("og:" <> url)

    case read_meta(key) do
      %{} = embed ->
        embed

      :fail ->
        nil

      nil ->
        case Rest.fetch_og(url) do
          nil ->
            write_meta(key, %{kind: :og, href: url, fail: true})
            nil

          body when is_map(body) ->
            title = blank_to_nil(body["title"])
            desc = clean_description(body["description"])
            site = blank_to_nil(body["site_name"])
            image = blank_to_nil(body["image"])

            if is_nil(title) and is_nil(desc) and is_nil(image) do
              write_meta(key, %{kind: :og, href: url, fail: true})
              nil
            else
              image_url = if image, do: cache_remote_image(image), else: nil

              embed = %{
                kind: :og,
                href: url,
                title: title,
                description: desc,
                site_name: site,
                domain: domain_of(url),
                image_url: image_url
              }

              write_meta(key, embed)
              embed
            end
        end
    end
  end

  # ── image cache ────────────────────────────────────────────────────────

  defp cache_remote_image(nil), do: nil
  defp cache_remote_image(""), do: nil

  defp cache_remote_image(remote_url) when is_binary(remote_url) do
    id_base = :crypto.hash(:sha256, remote_url) |> Base.encode16(case: :lower) |> String.slice(0, 32)

    # Prefer existing file with any known extension
    case find_existing_image(id_base) do
      path when is_binary(path) ->
        "/preview-cache/#{Path.basename(path)}"

      nil ->
        download_image(remote_url, id_base)
    end
  rescue
    _ -> nil
  end

  defp find_existing_image(id_base) do
    dir = cache_dir()

    Enum.find_value(~w(jpg jpeg png gif webp), fn ext ->
      path = Path.join(dir, "#{id_base}.#{ext}")
      if File.exists?(path), do: path
    end)
  end

  defp download_image(remote_url, id_base) do
    case Req.get(remote_url,
           receive_timeout: 8_000,
           connect_options: [timeout: 4_000],
           headers: [{"user-agent", "freeq-web3/1.0 (link preview cache)"}],
           max_redirects: 3
         ) do
      {:ok, %{status: status, body: body, headers: headers}}
      when status in 200..299 and is_binary(body) and byte_size(body) > 0 and
             byte_size(body) <= 2_000_000 ->
        ct = header_ct(headers)
        ext = ext_for_content_type(ct, remote_url)
        id = "#{id_base}.#{ext}"
        path = Path.join(cache_dir(), id)
        File.mkdir_p!(cache_dir())
        File.write!(path, body)
        File.chmod!(path, 0o644)
        "/preview-cache/#{id}"

      _ ->
        nil
    end
  rescue
    e ->
      Logger.debug("preview image download failed: #{Exception.message(e)}")
      nil
  end

  defp header_ct(headers) when is_map(headers) do
    case headers["content-type"] || headers["Content-Type"] do
      [v | _] -> v
      v when is_binary(v) -> v
      _ -> ""
    end
  end

  defp header_ct(headers) when is_list(headers) do
    Enum.find_value(headers, "", fn
      {k, v} ->
        if String.downcase(to_string(k)) == "content-type" do
          case v do
            [x | _] -> x
            x when is_binary(x) -> x
            _ -> ""
          end
        end

      _ ->
        nil
    end) || ""
  end

  defp header_ct(_), do: ""

  defp ext_for_content_type(ct, url) do
    ct = String.downcase(ct || "")

    cond do
      String.contains?(ct, "png") -> "png"
      String.contains?(ct, "gif") -> "gif"
      String.contains?(ct, "webp") -> "webp"
      String.contains?(ct, "jpeg") or String.contains?(ct, "jpg") -> "jpg"
      String.ends_with?(URI.parse(url).path || "", ".png") -> "png"
      String.ends_with?(URI.parse(url).path || "", ".gif") -> "gif"
      String.ends_with?(URI.parse(url).path || "", ".webp") -> "webp"
      true -> "jpg"
    end
  end

  defp content_type_for(id) do
    cond do
      String.ends_with?(id, ".png") -> "image/png"
      String.ends_with?(id, ".gif") -> "image/gif"
      String.ends_with?(id, ".webp") -> "image/webp"
      true -> "image/jpeg"
    end
  end

  defp valid_image_id?(id) do
    Regex.match?(~r/\A[a-f0-9]{16,64}\.(jpg|jpeg|png|gif|webp)\z/i, id)
  end

  # ── meta cache ─────────────────────────────────────────────────────────

  defp cache_key(s), do: :crypto.hash(:sha256, s) |> Base.encode16(case: :lower) |> String.slice(0, 40)

  defp page_key(text) do
    cond do
      m = Regex.run(@bsky_post_re, text) ->
        cache_key("bsky:#{Enum.at(m, 1)}/#{Enum.at(m, 2)}")

      m = Regex.run(@yt_re, text) ->
        cache_key("yt:" <> Enum.at(m, 1))

      has_inline_image?(text) ->
        nil

      url = first_embeddable_url(text) ->
        cache_key("og:" <> url)

      true ->
        nil
    end
  end

  defp meta_path(key), do: Path.join(cache_dir(), "#{key}.json")

  defp read_meta(key) do
    path = meta_path(key)

    with true <- File.exists?(path),
         {:ok, raw} <- File.read(path),
         {:ok, data} <- Jason.decode(raw) do
      if data["fail"] == true do
        :fail
      else
        atomize_embed(data)
      end
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp write_meta(key, embed) when is_map(embed) do
    File.mkdir_p!(cache_dir())
    path = meta_path(key)
    # Store with string keys for JSON
    data =
      embed
      |> Map.put(:cached_at, System.system_time(:second))
      |> stringify_keys()

    File.write!(path, Jason.encode!(data))
    File.chmod!(path, 0o600)
    :ok
  rescue
    e ->
      Logger.debug("write preview meta failed: #{Exception.message(e)}")
      :ok
  end

  defp atomize_embed(data) when is_map(data) do
    kind =
      case data["kind"] || data[:kind] do
        "youtube" -> :youtube
        "bsky" -> :bsky
        "og" -> :og
        :youtube -> :youtube
        :bsky -> :bsky
        :og -> :og
        _ -> :og
      end

    bsky =
      case data["bsky"] || data[:bsky] do
        %{} = b ->
          %{
            display: b["display"] || b[:display],
            handle: b["handle"] || b[:handle],
            text: b["text"] || b[:text],
            likes: b["likes"] || b[:likes] || 0,
            reposts: b["reposts"] || b[:reposts] || 0,
            time: b["time"] || b[:time],
            avatar_url: b["avatar_url"] || b[:avatar_url]
          }

        _ ->
          nil
      end

    %{
      kind: kind,
      href: data["href"] || data[:href],
      title: data["title"] || data[:title],
      description: data["description"] || data[:description],
      site_name: data["site_name"] || data[:site_name],
      domain: data["domain"] || data[:domain],
      image_url: data["image_url"] || data[:image_url],
      video_id: data["video_id"] || data[:video_id],
      bsky: bsky
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_val(v)}
      {k, v} -> {k, stringify_val(v)}
    end)
  end

  defp stringify_val(%{} = m), do: stringify_keys(m)
  defp stringify_val(v), do: v

  # ── URL helpers ────────────────────────────────────────────────────────

  defp first_embeddable_url(text) do
    @url_re
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.find_value(fn raw ->
      url = clean_url(raw)

      cond do
        url == "" -> nil
        image_url?(url) -> nil
        Regex.match?(@skip_re, url) -> nil
        true ->
          case URI.parse(url) do
            %URI{scheme: s} when s in ["http", "https"] -> url
            _ -> nil
          end
      end
    end)
  end

  defp has_inline_image?(text) do
    @url_re
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.any?(fn raw -> image_url?(clean_url(raw)) end)
  end

  defp image_url?(url) do
    Regex.match?(@image_url_re, url) or Regex.match?(@media_re, url) or
      Regex.match?(@bsky_cdn_re, url)
  end

  defp clean_url(raw) do
    url =
      raw
      |> to_string()
      |> String.replace(~r/[\x{200B}-\x{200D}\x{FEFF}\x{2060}\x{00AD}]/u, "")
      |> String.trim()
      |> String.trim_leading("<")
      |> String.trim_trailing(">")

    # strip trailing punctuation
    String.replace(url, ~r/[.,;:!?)'"\]]+\z/, "")
  end

  defp domain_of(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> String.replace_prefix(host, "www.", "")
      _ -> ""
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(s) when is_binary(s) do
    t = String.trim(s)
    if t == "", do: nil, else: t
  end

  defp blank_to_nil(_), do: nil

  defp clean_description(nil), do: nil

  defp clean_description(desc) do
    d = desc |> to_string() |> String.trim()
    d = Regex.replace(~r/^(?:\.[^{]+\{[^}]*\}\s*)+/u, d, "")
    d = Regex.replace(~r/^(?:[^{]+\{[^}]*\}\s*)+/u, d, "")
    d = String.trim(d)

    cond do
      String.length(d) < 8 -> nil
      Regex.match?(~r/[{};]/, d) and String.length(d) < 40 -> nil
      true -> d
    end
  end

  defp format_bsky_time(nil), do: ""

  defp format_bsky_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%b %d, %Y")
      _ -> ""
    end
  end

  defp format_bsky_time(_), do: ""

  def cache_dir do
    raw =
      Application.get_env(
        :freeq_web3,
        :preview_cache_dir,
        System.get_env("FREEQ_WEB3_PREVIEW_CACHE_DIR", ".dev-data/web3-preview-cache")
      )

    if Path.type(raw) == :absolute, do: raw, else: Path.expand(raw)
  end
end
