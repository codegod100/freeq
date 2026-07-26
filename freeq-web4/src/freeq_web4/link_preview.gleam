//// Server-side link previews with a local image cache.
////
//// Port of freeq-web3 `LinkPreview`. Resolves YouTube / Bluesky / OpenGraph
//// cards for message text, downloads remote images into `preview_cache_dir`,
//// and serves them as same-origin `/preview-cache/:id` URLs.

import filepath
import freeq_web4/config
import freeq_web4/irc/render
import freeq_web4/rest
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/uri
import logging
import simplifile

// ── Public API ───────────────────────────────────────────────────────────────

/// Attach a resolved embed (network + cache) to a message row.
pub fn attach(row: render.Row) -> render.Row {
  case row.kind, row.embed {
    render.Msg, None ->
      case resolve(row.text) {
        Some(embed) -> render.Row(..row, embed: Some(embed))
        None -> row
      }
    _, _ -> row
  }
}

/// Disk-cache only (no network). Safe for fast history paint.
pub fn attach_cache_only(row: render.Row) -> render.Row {
  case row.kind, row.embed {
    render.Msg, None ->
      case page_key(row.text) {
        None -> row
        Some(key) ->
          case read_meta(key) {
            Ok(embed) -> render.Row(..row, embed: Some(embed))
            Error(_) -> row
          }
      }
    _, _ -> row
  }
}

/// Attach cache-only embeds to every row.
pub fn attach_many_cache_only(rows: List(render.Row)) -> List(render.Row) {
  list.map(rows, attach_cache_only)
}

/// Resolve first embeddable URL in `text` (network + cache).
pub fn resolve(text: String) -> Option(render.Embed) {
  case extract_bsky(text) {
    Some(#(href, handle, rkey)) -> resolve_bsky(href, handle, rkey)
    None ->
      case extract_youtube(text) {
        Some(video_id) -> resolve_youtube(video_id)
        None ->
          case has_inline_image(text) {
            True -> None
            False ->
              case first_embeddable_url(text) {
                Some(url) -> resolve_og(url)
                None -> None
              }
          }
      }
  }
}

/// True when a msg row still needs a network preview resolve.
pub fn needs_resolve(row: render.Row) -> Bool {
  case row.kind, row.embed {
    render.Msg, None ->
      string.contains(row.text, "http://")
      || string.contains(row.text, "https://")
    _, _ -> False
  }
}

/// Read a cached image by id → `#(bytes, content_type)` or error.
pub fn read_image(id: String) -> Result(#(BitArray, String), Nil) {
  case valid_image_id(id) {
    False -> Error(Nil)
    True -> {
      let path = filepath.join(config.preview_cache_dir(), id)
      case simplifile.read_bits(path) {
        Ok(bin) -> Ok(#(bin, content_type_for(id)))
        Error(_) -> Error(Nil)
      }
    }
  }
}

// ── Resolvers ────────────────────────────────────────────────────────────────

fn resolve_youtube(video_id: String) -> Option(render.Embed) {
  let href = "https://youtube.com/watch?v=" <> video_id
  let key = cache_key("yt:" <> video_id)
  case read_meta(key) {
    Ok(embed) -> Some(embed)
    Error(Failed) -> None
    Error(Missing) -> {
      let remote =
        "https://img.youtube.com/vi/" <> video_id <> "/mqdefault.jpg"
      let image_url = cache_remote_image(remote)
      let embed =
        render.Embed(
          kind: render.Youtube,
          href: href,
          title: Some("YouTube"),
          description: None,
          site_name: None,
          domain: Some("youtube.com"),
          image_url: image_url,
          video_id: Some(video_id),
          bsky: None,
        )
      write_meta(key, embed)
      Some(embed)
    }
  }
}

fn resolve_bsky(
  href: String,
  handle: String,
  rkey: String,
) -> Option(render.Embed) {
  let key = cache_key("bsky:" <> handle <> "/" <> rkey)
  case read_meta(key) {
    Ok(embed) -> Some(embed)
    Error(Failed) -> None
    Error(Missing) -> {
      let at_uri = "at://" <> handle <> "/app.bsky.feed.post/" <> rkey
      let url =
        "https://public.api.bsky.app/xrpc/app.bsky.feed.getPostThread?uri="
        <> uri.percent_encode(at_uri)
        <> "&depth=0"
      case get_json_map(url) {
        Error(_) -> {
          write_fail(key)
          None
        }
        Ok(body) ->
          case parse_bsky_thread(body, href, handle) {
            None -> {
              write_fail(key)
              None
            }
            Some(embed) -> {
              write_meta(key, embed)
              Some(embed)
            }
          }
      }
    }
  }
}

fn parse_bsky_thread(
  body: String,
  href: String,
  fallback_handle: String,
) -> Option(render.Embed) {
  let author_decoder = {
    use handle <- decode.optional_field("handle", "", decode.string)
    use display_name <- decode.optional_field("displayName", "", decode.string)
    use avatar <- decode.optional_field("avatar", "", decode.string)
    decode.success(#(handle, display_name, avatar))
  }
  let record_decoder = {
    use text <- decode.optional_field("text", "", decode.string)
    use created_at <- decode.optional_field("createdAt", "", decode.string)
    decode.success(#(text, created_at))
  }
  let post_decoder = {
    use author <- decode.optional_field(
      "author",
      #("", "", ""),
      author_decoder,
    )
    use record <- decode.optional_field("record", #("", ""), record_decoder)
    use like_count <- decode.optional_field("likeCount", 0, decode.int)
    use repost_count <- decode.optional_field("repostCount", 0, decode.int)
    use embed_images <- decode.optional_field(
      "embed",
      [],
      bsky_images_decoder(),
    )
    decode.success(#(author, record, like_count, repost_count, embed_images))
  }
  let thread_decoder = {
    use post <- decode.subfield(["thread", "post"], post_decoder)
    decode.success(post)
  }
  case json.parse(body, thread_decoder) {
    Error(_) -> None
    Ok(#(author, record, likes, reposts, images)) -> {
      let #(handle_raw, display_raw, avatar_raw) = author
      let #(text, created) = record
      let handle_label = case handle_raw {
        "" -> fallback_handle
        h -> h
      }
      let display = case display_raw {
        "" -> handle_label
        d -> d
      }
      let avatar_remote = case avatar_raw {
        "" -> None
        a -> Some(a)
      }
      let image_remote = case images {
        [first, ..] -> Some(first)
        [] -> avatar_remote
      }
      let image_url = case image_remote {
        Some(u) -> cache_remote_image(u)
        None -> None
      }
      let avatar_url = case avatar_remote {
        Some(u) -> cache_remote_image(u)
        None -> None
      }
      Some(
        render.Embed(
          kind: render.Bsky,
          href: href,
          title: Some(display),
          description: Some(string.slice(text, 0, 280)),
          site_name: None,
          domain: Some("bsky.app"),
          image_url: image_url,
          video_id: None,
          bsky: Some(
            render.BskyMeta(
              display: display,
              handle: handle_label,
              text: text,
              likes: likes,
              reposts: reposts,
              time: format_bsky_time(created),
              avatar_url: avatar_url,
            ),
          ),
        ),
      )
    }
  }
}

fn bsky_images_decoder() -> decode.Decoder(List(String)) {
  decode.one_of(
    {
      use images <- decode.optional_field(
        "images",
        [],
        decode.list({
          use thumb <- decode.optional_field("thumb", "", decode.string)
          use fullsize <- decode.optional_field("fullsize", "", decode.string)
          decode.success(case thumb {
            "" -> fullsize
            t -> t
          })
        }),
      )
      decode.success(list.filter(images, fn(u) { u != "" }))
    },
    or: [
      {
        use media <- decode.optional_field(
          "media",
          None,
          decode.optional({
            use images <- decode.optional_field(
              "images",
              [],
              decode.list({
                use thumb <- decode.optional_field("thumb", "", decode.string)
                use fullsize <- decode.optional_field(
                  "fullsize",
                  "",
                  decode.string,
                )
                decode.success(case thumb {
                  "" -> fullsize
                  t -> t
                })
              }),
            )
            decode.success(list.filter(images, fn(u) { u != "" }))
          }),
        )
        decode.success(case media {
          Some(imgs) -> imgs
          None -> []
        })
      },
      decode.success([]),
    ],
  )
}

fn resolve_og(url: String) -> Option(render.Embed) {
  let key = cache_key("og:" <> url)
  case read_meta(key) {
    Ok(embed) -> Some(embed)
    Error(Failed) -> None
    Error(Missing) ->
      case rest.fetch_og(url) {
        None -> {
          write_fail(key)
          None
        }
        Some(meta) -> {
          let title = blank_to_none(meta.title)
          let desc = clean_description(meta.description)
          let site = blank_to_none(meta.site_name)
          let image = blank_to_none(meta.image)
          case title, desc, image {
            None, None, None -> {
              write_fail(key)
              None
            }
            _, _, _ -> {
              let image_url = case image {
                Some(img) -> cache_remote_image(img)
                None -> None
              }
              let embed =
                render.Embed(
                  kind: render.Og,
                  href: url,
                  title: title,
                  description: desc,
                  site_name: site,
                  domain: Some(domain_of(url)),
                  image_url: image_url,
                  video_id: None,
                  bsky: None,
                )
              write_meta(key, embed)
              Some(embed)
            }
          }
        }
      }
  }
}

// ── Image cache ──────────────────────────────────────────────────────────────

fn cache_remote_image(remote_url: String) -> Option(String) {
  case string.trim(remote_url) {
    "" -> None
    url -> {
      let id_base =
        crypto.hash(crypto.Sha256, <<url:utf8>>)
        |> bit_array.base16_encode
        |> string.lowercase
        |> string.slice(0, 32)
      case find_existing_image(id_base) {
        Some(name) -> Some("/preview-cache/" <> name)
        None -> download_image(url, id_base)
      }
    }
  }
}

fn find_existing_image(id_base: String) -> Option(String) {
  let dir = config.preview_cache_dir()
  list.find_map(["jpg", "jpeg", "png", "gif", "webp"], fn(ext) {
    let name = id_base <> "." <> ext
    let path = filepath.join(dir, name)
    case simplifile.is_file(path) {
      Ok(True) -> Ok(name)
      _ -> Error(Nil)
    }
  })
  |> result_to_option
}

fn result_to_option(r: Result(a, b)) -> Option(a) {
  case r {
    Ok(v) -> Some(v)
    Error(_) -> None
  }
}

fn download_image(remote_url: String, id_base: String) -> Option(String) {
  case request.to(remote_url) {
    Error(_) -> None
    Ok(req) -> {
      let req =
        req
        |> request.set_method(http.Get)
        |> request.set_header(
          "user-agent",
          "freeq-web4/1.0 (link preview cache)",
        )
        |> request.set_body(<<>>)
      case
        httpc.configure()
        |> httpc.timeout(8000)
        |> httpc.follow_redirects(True)
        |> httpc.dispatch_bits(req)
      {
        Ok(resp) if resp.status >= 200 && resp.status < 300 -> {
          let size = bit_array.byte_size(resp.body)
          case size > 0 && size <= 2_000_000 {
            False -> None
            True -> {
              let ct = header_value(resp.headers, "content-type")
              let ext = ext_for_content_type(ct, remote_url)
              let id = id_base <> "." <> ext
              let dir = config.preview_cache_dir()
              let path = filepath.join(dir, id)
              let _ = simplifile.create_directory_all(dir)
              case simplifile.write_bits(path, resp.body) {
                Ok(_) -> Some("/preview-cache/" <> id)
                Error(_) -> None
              }
            }
          }
        }
        _ -> None
      }
    }
  }
}

fn header_value(headers: List(#(String, String)), name: String) -> String {
  let want = string.lowercase(name)
  case
    list.find(headers, fn(h) { string.lowercase(h.0) == want })
  {
    Ok(#(_, v)) -> v
    Error(_) -> ""
  }
}

fn ext_for_content_type(ct: String, url: String) -> String {
  let ct = string.lowercase(ct)
  case
    string.contains(ct, "png"),
    string.contains(ct, "gif"),
    string.contains(ct, "webp"),
    string.contains(ct, "jpeg") || string.contains(ct, "jpg")
  {
    True, _, _, _ -> "png"
    _, True, _, _ -> "gif"
    _, _, True, _ -> "webp"
    _, _, _, True -> "jpg"
    _, _, _, _ -> {
      let path = case uri.parse(url) {
        Ok(u) -> u.path
        Error(_) -> url
      }
      let path = string.lowercase(path)
      case
        string.ends_with(path, ".png"),
        string.ends_with(path, ".gif"),
        string.ends_with(path, ".webp")
      {
        True, _, _ -> "png"
        _, True, _ -> "gif"
        _, _, True -> "webp"
        _, _, _ -> "jpg"
      }
    }
  }
}

fn content_type_for(id: String) -> String {
  let lower = string.lowercase(id)
  case
    string.ends_with(lower, ".png"),
    string.ends_with(lower, ".gif"),
    string.ends_with(lower, ".webp")
  {
    True, _, _ -> "image/png"
    _, True, _ -> "image/gif"
    _, _, True -> "image/webp"
    _, _, _ -> "image/jpeg"
  }
}

fn valid_image_id(id: String) -> Bool {
  case string.contains(id, "/") || string.contains(id, "..") || id == "" {
    True -> False
    False -> {
      case string.split_once(id, ".") {
        Error(_) -> False
        Ok(#(hex, ext)) -> {
          let hex_ok =
            string.length(hex) >= 16
            && string.length(hex) <= 64
            && is_hex(hex)
          let ext_ok = case string.lowercase(ext) {
            "jpg" | "jpeg" | "png" | "gif" | "webp" -> True
            _ -> False
          }
          hex_ok && ext_ok
        }
      }
    }
  }
}

fn is_hex(s: String) -> Bool {
  string.to_graphemes(s)
  |> list.all(fn(g) {
    case g {
      "0"
      | "1"
      | "2"
      | "3"
      | "4"
      | "5"
      | "6"
      | "7"
      | "8"
      | "9"
      | "a"
      | "b"
      | "c"
      | "d"
      | "e"
      | "f"
      | "A"
      | "B"
      | "C"
      | "D"
      | "E"
      | "F" -> True
      _ -> False
    }
  })
}

// ── Meta cache ───────────────────────────────────────────────────────────────

type MetaRead {
  Failed
  Missing
}

fn cache_key(s: String) -> String {
  crypto.hash(crypto.Sha256, <<s:utf8>>)
  |> bit_array.base16_encode
  |> string.lowercase
  |> string.slice(0, 40)
}

fn page_key(text: String) -> Option(String) {
  case extract_bsky(text) {
    Some(#(_, handle, rkey)) ->
      Some(cache_key("bsky:" <> handle <> "/" <> rkey))
    None ->
      case extract_youtube(text) {
        Some(vid) -> Some(cache_key("yt:" <> vid))
        None ->
          case has_inline_image(text) {
            True -> None
            False ->
              case first_embeddable_url(text) {
                Some(url) -> Some(cache_key("og:" <> url))
                None -> None
              }
          }
      }
  }
}

fn meta_path(key: String) -> String {
  filepath.join(config.preview_cache_dir(), key <> ".json")
}

fn read_meta(key: String) -> Result(render.Embed, MetaRead) {
  case simplifile.read(meta_path(key)) {
    Error(_) -> Error(Missing)
    Ok(raw) ->
      case json.parse(raw, embed_decoder()) {
        Error(_) -> Error(Missing)
        Ok(meta) ->
          case meta.fail {
            True -> Error(Failed)
            False ->
              case meta.embed {
                Some(e) -> Ok(e)
                None -> Error(Failed)
              }
          }
      }
  }
}

type StoredMeta {
  StoredMeta(fail: Bool, embed: Option(render.Embed))
}

fn embed_decoder() -> decode.Decoder(StoredMeta) {
  use fail <- decode.optional_field("fail", False, decode.bool)
  use kind <- decode.optional_field("kind", "og", decode.string)
  use href <- decode.optional_field("href", "", decode.string)
  use title <- decode.optional_field("title", None, decode.optional(decode.string))
  use description <- decode.optional_field(
    "description",
    None,
    decode.optional(decode.string),
  )
  use site_name <- decode.optional_field(
    "site_name",
    None,
    decode.optional(decode.string),
  )
  use domain <- decode.optional_field(
    "domain",
    None,
    decode.optional(decode.string),
  )
  use image_url <- decode.optional_field(
    "image_url",
    None,
    decode.optional(decode.string),
  )
  use video_id <- decode.optional_field(
    "video_id",
    None,
    decode.optional(decode.string),
  )
  use bsky <- decode.optional_field("bsky", None, decode.optional(bsky_meta_decoder()))
  case fail || href == "" {
    True -> decode.success(StoredMeta(fail: True, embed: None))
    False -> {
      let embed_kind = case kind {
        "youtube" -> render.Youtube
        "bsky" -> render.Bsky
        _ -> render.Og
      }
      decode.success(
        StoredMeta(
          fail: False,
          embed: Some(
            render.Embed(
              kind: embed_kind,
              href: href,
              title: title,
              description: description,
              site_name: site_name,
              domain: domain,
              image_url: image_url,
              video_id: video_id,
              bsky: bsky,
            ),
          ),
        ),
      )
    }
  }
}

fn bsky_meta_decoder() -> decode.Decoder(render.BskyMeta) {
  use display <- decode.optional_field("display", "", decode.string)
  use handle <- decode.optional_field("handle", "", decode.string)
  use text <- decode.optional_field("text", "", decode.string)
  use likes <- decode.optional_field("likes", 0, decode.int)
  use reposts <- decode.optional_field("reposts", 0, decode.int)
  use time <- decode.optional_field("time", "", decode.string)
  use avatar_url <- decode.optional_field(
    "avatar_url",
    None,
    decode.optional(decode.string),
  )
  decode.success(
    render.BskyMeta(
      display: display,
      handle: handle,
      text: text,
      likes: likes,
      reposts: reposts,
      time: time,
      avatar_url: avatar_url,
    ),
  )
}

fn write_meta(key: String, embed: render.Embed) -> Nil {
  let dir = config.preview_cache_dir()
  let _ = simplifile.create_directory_all(dir)
  let path = meta_path(key)
  let body = encode_embed(embed, False)
  case simplifile.write(path, body) {
    Ok(_) -> Nil
    Error(e) -> {
      logging.log(
        logging.Debug,
        "write preview meta failed: " <> string.inspect(e),
      )
      Nil
    }
  }
}

fn write_fail(key: String) -> Nil {
  let dir = config.preview_cache_dir()
  let _ = simplifile.create_directory_all(dir)
  let path = meta_path(key)
  let body = "{\"fail\":true,\"kind\":\"og\",\"href\":\"\"}"
  let _ = simplifile.write(path, body)
  Nil
}

fn encode_embed(embed: render.Embed, fail: Bool) -> String {
  let kind = case embed.kind {
    render.Youtube -> "youtube"
    render.Bsky -> "bsky"
    render.Og -> "og"
  }
  let fields = [
    #("fail", json.bool(fail)),
    #("kind", json.string(kind)),
    #("href", json.string(embed.href)),
  ]
  let fields = opt_string_field(fields, "title", embed.title)
  let fields = opt_string_field(fields, "description", embed.description)
  let fields = opt_string_field(fields, "site_name", embed.site_name)
  let fields = opt_string_field(fields, "domain", embed.domain)
  let fields = opt_string_field(fields, "image_url", embed.image_url)
  let fields = opt_string_field(fields, "video_id", embed.video_id)
  let fields = case embed.bsky {
    None -> fields
    Some(b) -> {
      let bsky_fields = [
        #("display", json.string(b.display)),
        #("handle", json.string(b.handle)),
        #("text", json.string(b.text)),
        #("likes", json.int(b.likes)),
        #("reposts", json.int(b.reposts)),
        #("time", json.string(b.time)),
      ]
      let bsky_fields = case b.avatar_url {
        Some(a) -> list.append(bsky_fields, [#("avatar_url", json.string(a))])
        None -> bsky_fields
      }
      list.append(fields, [#("bsky", json.object(bsky_fields))])
    }
  }
  json.object(fields) |> json.to_string
}

fn opt_string_field(
  fields: List(#(String, json.Json)),
  key: String,
  value: Option(String),
) -> List(#(String, json.Json)) {
  case value {
    Some(v) -> list.append(fields, [#(key, json.string(v))])
    None -> fields
  }
}

// ── URL helpers ──────────────────────────────────────────────────────────────

fn extract_bsky(text: String) -> Option(#(String, String, String)) {
  // https://bsky.app/profile/{handle}/post/{rkey}
  case string.split_once(text, "bsky.app/profile/") {
    Error(_) -> None
    Ok(#(before, rest)) -> {
      let scheme = case string.contains(before, "https://") {
        True -> "https://"
        False ->
          case string.contains(before, "http://") {
            True -> "http://"
            False -> "https://"
          }
      }
      // Prefer the last scheme occurrence before the host.
      let scheme = case string.ends_with(before, "https://") {
        True -> "https://"
        False ->
          case string.ends_with(before, "http://") {
            True -> "http://"
            False -> scheme
          }
      }
      case string.split_once(rest, "/post/") {
        Error(_) -> None
        Ok(#(handle, after)) -> {
          let handle = string.trim(handle)
          let #(rkey, _) = take_token(after)
          let rkey = strip_trailing_punct(rkey)
          case handle != "" && rkey != "" && is_bsky_rkey(rkey) {
            False -> None
            True -> {
              let href =
                scheme <> "bsky.app/profile/" <> handle <> "/post/" <> rkey
              Some(#(href, handle, rkey))
            }
          }
        }
      }
    }
  }
}

fn extract_youtube(text: String) -> Option(String) {
  case extract_youtube_watch(text) {
    Some(id) -> Some(id)
    None ->
      case extract_youtube_be(text) {
        Some(id) -> Some(id)
        None -> extract_youtube_shorts(text)
      }
  }
}

fn extract_youtube_watch(text: String) -> Option(String) {
  case string.split_once(text, "youtube.com/watch?") {
    Error(_) -> None
    Ok(#(_, qs_and_more)) -> {
      let #(qs, _) = take_until_ws(qs_and_more)
      youtube_v_param(qs)
    }
  }
}

fn extract_youtube_be(text: String) -> Option(String) {
  case string.split_once(text, "youtu.be/") {
    Error(_) -> None
    Ok(#(_, rest)) -> {
      let #(id, _) = take_token(rest)
      let id = strip_trailing_punct(id)
      case is_youtube_id(id) {
        True -> Some(id)
        False -> None
      }
    }
  }
}

fn extract_youtube_shorts(text: String) -> Option(String) {
  case string.split_once(text, "youtube.com/shorts/") {
    Error(_) -> None
    Ok(#(_, rest)) -> {
      let #(id, _) = take_token(rest)
      let id = strip_trailing_punct(id)
      case is_youtube_id(id) {
        True -> Some(id)
        False -> None
      }
    }
  }
}

fn youtube_v_param(qs: String) -> Option(String) {
  // Find v=… in query string (may include other params).
  case string.split_once(qs, "v=") {
    Error(_) -> None
    Ok(#(_, rest)) -> {
      let #(id, _) = take_query_value(rest)
      case is_youtube_id(id) {
        True -> Some(id)
        False -> None
      }
    }
  }
}

fn is_youtube_id(id: String) -> Bool {
  string.length(id) == 11 && is_youtube_id_chars(id)
}

fn is_youtube_id_chars(id: String) -> Bool {
  string.to_graphemes(id)
  |> list.all(fn(g) {
    case g {
      "A"
      | "B"
      | "C"
      | "D"
      | "E"
      | "F"
      | "G"
      | "H"
      | "I"
      | "J"
      | "K"
      | "L"
      | "M"
      | "N"
      | "O"
      | "P"
      | "Q"
      | "R"
      | "S"
      | "T"
      | "U"
      | "V"
      | "W"
      | "X"
      | "Y"
      | "Z"
      | "a"
      | "b"
      | "c"
      | "d"
      | "e"
      | "f"
      | "g"
      | "h"
      | "i"
      | "j"
      | "k"
      | "l"
      | "m"
      | "n"
      | "o"
      | "p"
      | "q"
      | "r"
      | "s"
      | "t"
      | "u"
      | "v"
      | "w"
      | "x"
      | "y"
      | "z"
      | "0"
      | "1"
      | "2"
      | "3"
      | "4"
      | "5"
      | "6"
      | "7"
      | "8"
      | "9"
      | "-"
      | "_" -> True
      _ -> False
    }
  })
}

fn is_bsky_rkey(rkey: String) -> Bool {
  string.length(rkey) > 0
  && string.to_graphemes(rkey)
  |> list.all(fn(g) {
    case g {
      "A"
      | "B"
      | "C"
      | "D"
      | "E"
      | "F"
      | "G"
      | "H"
      | "I"
      | "J"
      | "K"
      | "L"
      | "M"
      | "N"
      | "O"
      | "P"
      | "Q"
      | "R"
      | "S"
      | "T"
      | "U"
      | "V"
      | "W"
      | "X"
      | "Y"
      | "Z"
      | "a"
      | "b"
      | "c"
      | "d"
      | "e"
      | "f"
      | "g"
      | "h"
      | "i"
      | "j"
      | "k"
      | "l"
      | "m"
      | "n"
      | "o"
      | "p"
      | "q"
      | "r"
      | "s"
      | "t"
      | "u"
      | "v"
      | "w"
      | "x"
      | "y"
      | "z"
      | "0"
      | "1"
      | "2"
      | "3"
      | "4"
      | "5"
      | "6"
      | "7"
      | "8"
      | "9" -> True
      _ -> False
    }
  })
}

fn first_embeddable_url(text: String) -> Option(String) {
  first_url_loop(text)
}

fn first_url_loop(rest: String) -> Option(String) {
  case next_http_split(rest) {
    None -> None
    Some(#(_before, scheme, after)) -> {
      let #(raw, more) = take_until_ws(after)
      let url = strip_trailing_punct(raw)
      let full = scheme <> url
      case url == "" {
        True -> first_url_loop(more)
        False ->
          case is_skip_url(full) || render.is_image_url(full) {
            True -> first_url_loop(more)
            False ->
              case string.starts_with(full, "http://")
                || string.starts_with(full, "https://")
              {
                True -> Some(full)
                False -> first_url_loop(more)
              }
          }
      }
    }
  }
}

fn has_inline_image(text: String) -> Bool {
  case first_image_url(text) {
    Some(_) -> True
    None -> False
  }
}

fn first_image_url(rest: String) -> Option(String) {
  case next_http_split(rest) {
    None -> None
    Some(#(_, scheme, after)) -> {
      let #(raw, more) = take_until_ws(after)
      let url = strip_trailing_punct(raw)
      let full = scheme <> url
      case render.is_image_url(full) {
        True -> Some(full)
        False -> first_image_url(more)
      }
    }
  }
}

fn is_skip_url(url: String) -> Bool {
  let lower = string.lowercase(url)
  string.contains(lower, "/api/v1/")
  || string.ends_with(lower, ".m4a")
  || string.ends_with(lower, ".mp3")
  || string.ends_with(lower, ".mp4")
  || string.ends_with(lower, ".mov")
  || string.ends_with(lower, ".webm")
  || string.ends_with(lower, ".ogg")
  || string.ends_with(lower, ".wav")
  || string.ends_with(lower, ".aac")
  || string.contains(lower, ".m4a?")
  || string.contains(lower, ".mp3?")
  || string.contains(lower, ".mp4?")
  || string.contains(lower, ".mov?")
  || string.contains(lower, ".webm?")
}

fn next_http_split(rest: String) -> Option(#(String, String, String)) {
  let https = case string.split_once(rest, "https://") {
    Ok(#(pre, after)) -> Some(#(pre, "https://", after))
    Error(_) -> None
  }
  let http = case string.split_once(rest, "http://") {
    Ok(#(pre, after)) ->
      case string.starts_with(after, "s://") {
        True -> None
        False -> Some(#(pre, "http://", after))
      }
    Error(_) -> None
  }
  case https, http {
    Some(#(pre_s, sch_s, after_s)), Some(#(pre_h, sch_h, after_h)) ->
      case string.length(pre_s) <= string.length(pre_h) {
        True -> Some(#(pre_s, sch_s, after_s))
        False -> Some(#(pre_h, sch_h, after_h))
      }
    Some(h), None -> Some(h)
    None, Some(h) -> Some(h)
    None, None -> None
  }
}

fn take_until_ws(s: String) -> #(String, String) {
  take_until_ws_loop(s, "")
}

fn take_until_ws_loop(rest: String, acc: String) -> #(String, String) {
  case string.pop_grapheme(rest) {
    Error(Nil) -> #(acc, "")
    Ok(#(g, more)) ->
      case g {
        " " | "\t" | "\n" | "\r" | "<" -> #(acc, rest)
        _ -> take_until_ws_loop(more, acc <> g)
      }
  }
}

fn take_token(s: String) -> #(String, String) {
  take_token_loop(s, "")
}

fn take_token_loop(rest: String, acc: String) -> #(String, String) {
  case string.pop_grapheme(rest) {
    Error(Nil) -> #(acc, "")
    Ok(#(g, more)) ->
      case g {
        " " | "\t" | "\n" | "\r" | "<" | "?" | "#" | "/" | "&" -> #(acc, rest)
        _ -> take_token_loop(more, acc <> g)
      }
  }
}

fn take_query_value(s: String) -> #(String, String) {
  take_query_value_loop(s, "")
}

fn take_query_value_loop(rest: String, acc: String) -> #(String, String) {
  case string.pop_grapheme(rest) {
    Error(Nil) -> #(acc, "")
    Ok(#(g, more)) ->
      case g {
        " " | "\t" | "\n" | "\r" | "<" | "&" | "#" -> #(acc, rest)
        _ -> take_query_value_loop(more, acc <> g)
      }
  }
}

fn strip_trailing_punct(url: String) -> String {
  case string.pop_grapheme(string.reverse(url)) {
    Error(Nil) -> ""
    Ok(#(last, rev)) ->
      case last {
        "." | "," | ")" | "]" | "!" | "?" | ";" | "'" | "\"" ->
          strip_trailing_punct(string.reverse(rev))
        _ -> url
      }
  }
}

fn domain_of(url: String) -> String {
  case uri.parse(url) {
    Ok(u) ->
      case u.host {
        Some(host) ->
          case string.starts_with(host, "www.") {
            True -> string.drop_start(host, 4)
            False -> host
          }
        None -> ""
      }
    Error(_) -> ""
  }
}

fn blank_to_none(s: String) -> Option(String) {
  case string.trim(s) {
    "" -> None
    t -> Some(t)
  }
}

fn clean_description(desc: String) -> Option(String) {
  let d = string.trim(desc)
  case string.length(d) < 8 {
    True -> None
    False ->
      case
        string.contains(d, "{")
        && string.contains(d, "}")
        && string.length(d) < 40
      {
        True -> None
        False -> Some(d)
      }
  }
}

fn format_bsky_time(iso: String) -> String {
  // "2024-01-15T12:00:00.000Z" → "Jan 15, 2024" (best-effort)
  case string.split(iso, "T") {
    [date, ..] ->
      case string.split(date, "-") {
        [y, m, d] -> month_name(m) <> " " <> strip_leading_zero(d) <> ", " <> y
        _ -> ""
      }
    _ -> ""
  }
}

fn strip_leading_zero(s: String) -> String {
  case string.starts_with(s, "0") && string.length(s) == 2 {
    True -> string.drop_start(s, 1)
    False -> s
  }
}

fn month_name(m: String) -> String {
  case m {
    "01" -> "Jan"
    "02" -> "Feb"
    "03" -> "Mar"
    "04" -> "Apr"
    "05" -> "May"
    "06" -> "Jun"
    "07" -> "Jul"
    "08" -> "Aug"
    "09" -> "Sep"
    "10" -> "Oct"
    "11" -> "Nov"
    "12" -> "Dec"
    _ -> m
  }
}

fn get_json_map(url: String) -> Result(String, String) {
  case request.to(url) {
    Error(_) -> Error("bad_url")
    Ok(req) -> {
      let req =
        req
        |> request.set_method(http.Get)
        |> request.set_header("accept", "application/json")
      case
        httpc.configure()
        |> httpc.timeout(6000)
        |> httpc.dispatch(req)
      {
        Ok(resp) if resp.status == 200 -> Ok(resp.body)
        Ok(resp) -> Error("http_" <> int.to_string(resp.status))
        Error(_) -> Error("request_failed")
      }
    }
  }
}
