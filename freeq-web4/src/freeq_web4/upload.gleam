//// POST /upload — multipart proxy to freeq-server `/api/v1/upload`.
////
//// Browser FormData (file + optional channel/alt) is parsed, the session DID
//// is injected, and the payload is re-encoded for the upstream REST API.
//// freeq-server accepts the upload when the DID has an active IRC/WS session
//// (our BFF holds that after SASL).

import freeq_web4/config
import freeq_web4/cookie_session
import freeq_web4/session_store
import gleam/bit_array
import gleam/bytes_tree
import gleam/crypto
import gleam/http
import gleam/http/request as http_request
import gleam/http/response as http_response
import gleam/httpc
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import logging
import mist

const max_upload_bytes = 10_485_760

/// Handle `POST /upload`. Always returns a JSON response.
pub fn handle(
  req: http_request.Request(mist.Connection),
) -> http_response.Response(mist.ResponseData) {
  let sid = cookie_session.ensure_id(req)
  case session_store.load(sid) {
    Error(_) ->
      json_err(401, "Sign in to upload images")
    Ok(oauth) ->
      case string.starts_with(oauth.did, "did:") {
        False -> json_err(401, "Sign in to upload images")
        True -> read_and_proxy(req, oauth.did)
      }
  }
}

fn read_and_proxy(
  req: http_request.Request(mist.Connection),
  did: String,
) -> http_response.Response(mist.ResponseData) {
  // Allow a little overhead over the 10MB file limit for multipart framing.
  case mist.read_body(req, max_body_limit: max_upload_bytes + 256_000) {
    Error(mist.ExcessBody) -> json_err(413, "File too large (max 10MB)")
    Error(_) -> json_err(400, "Could not read upload body")
    Ok(with_body) -> {
      case parse_form(with_body) {
        Error(msg) -> json_err(422, msg)
        Ok(form) ->
          case bit_array.byte_size(form.bytes) {
            0 -> json_err(422, "Empty file")
            n if n > max_upload_bytes -> json_err(413, "File too large (max 10MB)")
            _ -> proxy_upstream(form, did)
          }
      }
    }
  }
}

type FormFile {
  FormFile(
    bytes: BitArray,
    filename: String,
    content_type: String,
    channel: String,
    alt: String,
  )
}

fn parse_form(
  req: http_request.Request(BitArray),
) -> Result(FormFile, String) {
  use boundary <- result.try(extract_boundary(req))
  case collect_parts(req.body, boundary, empty_acc()) {
    Error(_) -> Error("Invalid multipart body")
    Ok(acc) ->
      case acc.file {
        None -> Error("No file provided")
        Some(file) ->
          Ok(FormFile(
            bytes: file.0,
            filename: case file.1 {
              "" -> "screenshot.png"
              n -> n
            },
            content_type: case file.2 {
              "" -> "application/octet-stream"
              ct -> ct
            },
            channel: acc.channel,
            alt: acc.alt,
          ))
      }
  }
}

type Acc {
  Acc(
    file: Option(#(BitArray, String, String)),
    channel: String,
    alt: String,
  )
}

fn empty_acc() -> Acc {
  Acc(file: None, channel: "", alt: "")
}

fn collect_parts(
  data: BitArray,
  boundary: String,
  acc: Acc,
) -> Result(Acc, Nil) {
  case http.parse_multipart_headers(data, boundary) {
    Error(_) -> Error(Nil)
    Ok(http.MoreRequiredForHeaders(_)) -> Error(Nil)
    Ok(http.MultipartHeaders(headers: headers, remaining: rest)) -> {
      case headers {
        [] -> Ok(acc)
        _ -> {
          use body <- result.try(read_part_body(rest, boundary, <<>>))
          let #(chunk, done, remaining) = body
          let acc = apply_part(acc, headers, chunk)
          case done {
            True -> Ok(acc)
            False -> collect_parts(remaining, boundary, acc)
          }
        }
      }
    }
  }
}

fn read_part_body(
  data: BitArray,
  boundary: String,
  so_far: BitArray,
) -> Result(#(BitArray, Bool, BitArray), Nil) {
  case http.parse_multipart_body(data, boundary) {
    Error(_) -> Error(Nil)
    // Full body already buffered via mist.read_body — incomplete parse is fatal.
    Ok(http.MoreRequiredForBody(..)) -> Error(Nil)
    Ok(http.MultipartBody(chunk:, done:, remaining:)) ->
      Ok(#(bit_array.append(so_far, chunk), done, remaining))
  }
}

fn apply_part(
  acc: Acc,
  headers: List(#(String, String)),
  body: BitArray,
) -> Acc {
  let name = field_name(headers)
  let filename = field_filename(headers)
  let content_type = header_value(headers, "content-type")
  case name {
    "file" ->
      Acc(
        ..acc,
        file: Some(#(
          body,
          case filename {
            Some(n) -> n
            None -> "screenshot.png"
          },
          content_type,
        )),
      )
    "channel" -> Acc(..acc, channel: bits_to_text(body))
    "alt" -> Acc(..acc, alt: bits_to_text(body))
    // Client may send did; we ignore it and use the session DID.
    _ -> acc
  }
}

fn field_name(headers: List(#(String, String))) -> String {
  case header_value(headers, "content-disposition") {
    "" -> ""
    cd ->
      case http.parse_content_disposition(cd) {
        Ok(http.ContentDisposition(_, parameters: params)) ->
          list.key_find(params, "name") |> result.unwrap("")
        Error(_) -> ""
      }
  }
}

fn field_filename(headers: List(#(String, String))) -> Option(String) {
  case header_value(headers, "content-disposition") {
    "" -> None
    cd ->
      case http.parse_content_disposition(cd) {
        Ok(http.ContentDisposition(_, parameters: params)) ->
          case list.key_find(params, "filename") {
            Ok(n) if n != "" -> Some(n)
            _ -> None
          }
        Error(_) -> None
      }
  }
}

fn header_value(headers: List(#(String, String)), key: String) -> String {
  list.key_find(headers, string.lowercase(key))
  |> result.unwrap("")
}

fn bits_to_text(bits: BitArray) -> String {
  case bit_array.to_string(bits) {
    Ok(s) -> string.trim(s)
    Error(_) -> ""
  }
}

fn extract_boundary(
  req: http_request.Request(BitArray),
) -> Result(String, String) {
  case http_request.get_header(req, "content-type") {
    Error(_) -> Error("Expected multipart/form-data")
    Ok(ct) -> {
      let lower = string.lowercase(ct)
      case string.contains(lower, "multipart/form-data") {
        False -> Error("Expected multipart/form-data")
        True ->
          case find_param(ct, "boundary") {
            None | Some("") -> Error("Missing multipart boundary")
            Some(b) -> Ok(b)
          }
      }
    }
  }
}

/// Extract a semicolon-parameter from a header value (e.g. boundary=…).
fn find_param(header: String, name: String) -> Option(String) {
  let needle = string.lowercase(name) <> "="
  let parts = string.split(header, ";")
  list.find_map(parts, fn(part) {
    let trimmed = string.trim(part)
    let lower = string.lowercase(trimmed)
    case string.starts_with(lower, needle) {
      False -> Error(Nil)
      True -> {
        let raw = string.drop_start(trimmed, string.length(needle))
        Ok(unquote(string.trim(raw)))
      }
    }
  })
  |> option.from_result
}

fn unquote(s: String) -> String {
  case string.starts_with(s, "\"") && string.ends_with(s, "\"") {
    True ->
      s
      |> string.drop_start(1)
      |> string.drop_end(1)
    False -> s
  }
}

fn proxy_upstream(
  form: FormFile,
  did: String,
) -> http_response.Response(mist.ResponseData) {
  let url = config.upstream_rest() <> "/api/v1/upload"
  case http_request.to(url) {
    Error(_) -> json_err(502, "Bad upstream URL")
    Ok(req) -> {
      let boundary = "----FreeqWeb4" <> random_hex(16)
      let body = encode_multipart(form, did, boundary)
      let req =
        req
        |> http_request.set_method(http.Post)
        |> http_request.set_header(
          "content-type",
          "multipart/form-data; boundary=" <> boundary,
        )
        |> http_request.set_header(
          "content-length",
          int.to_string(bit_array.byte_size(body)),
        )
        |> http_request.set_body(body)
      case httpc.send_bits(req) {
        Error(err) -> {
          logging.log(
            logging.Warning,
            "upload proxy failed: " <> string.inspect(err),
          )
          json_err(502, "Upload failed")
        }
        Ok(resp) -> {
          let text = case bit_array.to_string(resp.body) {
            Ok(s) -> s
            Error(_) -> "{\"error\":\"invalid upstream response\"}"
          }
          let text = case string.trim(text) {
            "" ->
              "{\"error\":\"empty upstream response\",\"status\":"
              <> int.to_string(resp.status)
              <> "}"
            t -> t
          }
          // Pass through upstream status + JSON body.
          http_response.new(resp.status)
          |> http_response.set_header(
            "content-type",
            "application/json; charset=utf-8",
          )
          |> http_response.set_body(mist.Bytes(bytes_tree.from_string(text)))
        }
      }
    }
  }
}

/// Build an upstream multipart body (exported for unit tests).
pub fn encode_multipart_for_test(
  file_bytes: BitArray,
  filename: String,
  content_type: String,
  did: String,
  channel: String,
  alt: String,
  boundary: String,
) -> BitArray {
  encode_multipart(
    FormFile(
      bytes: file_bytes,
      filename: filename,
      content_type: content_type,
      channel: channel,
      alt: alt,
    ),
    did,
    boundary,
  )
}

fn encode_multipart(
  form: FormFile,
  did: String,
  boundary: String,
) -> BitArray {
  let dash = "--" <> boundary
  let parts = [
    text_part(dash, "did", did),
    case form.channel {
      "" -> <<>>
      ch -> text_part(dash, "channel", ch)
    },
    case form.alt {
      "" -> <<>>
      alt -> text_part(dash, "alt", alt)
    },
    file_part(dash, form),
    bit_array.from_string(dash <> "--\r\n"),
  ]
  bit_array.concat(parts)
}

fn text_part(dash: String, name: String, value: String) -> BitArray {
  bit_array.from_string(
    dash
    <> "\r\nContent-Disposition: form-data; name=\""
    <> name
    <> "\"\r\n\r\n"
    <> value
    <> "\r\n",
  )
}

fn file_part(dash: String, form: FormFile) -> BitArray {
  let safe_name =
    form.filename
    |> string.replace("\"", "")
    |> string.replace("\r", "")
    |> string.replace("\n", "")
  let header =
    bit_array.from_string(
      dash
      <> "\r\nContent-Disposition: form-data; name=\"file\"; filename=\""
      <> safe_name
      <> "\"\r\nContent-Type: "
      <> form.content_type
      <> "\r\n\r\n",
    )
  bit_array.concat([header, form.bytes, bit_array.from_string("\r\n")])
}

fn random_hex(n_bytes: Int) -> String {
  crypto.strong_random_bytes(n_bytes)
  |> bit_array.base16_encode
  |> string.lowercase
}

fn json_err(
  status: Int,
  message: String,
) -> http_response.Response(mist.ResponseData) {
  let body =
    "{\"error\":\""
    <> json_escape(message)
    <> "\"}"
  http_response.new(status)
  |> http_response.set_header("content-type", "application/json; charset=utf-8")
  |> http_response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn json_escape(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\r", "\\r")
}
