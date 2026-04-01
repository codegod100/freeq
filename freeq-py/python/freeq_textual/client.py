from __future__ import annotations

import base64
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
from typing import Any
from urllib.parse import parse_qs, quote, urlparse
from urllib.request import Request, urlopen

from ._freeq import FreeqAuthBroker as _FreeqAuthBroker
from ._freeq import FreeqClient as _FreeqClient


class FreeqClient:
    def __init__(
        self,
        server_addr: str,
        nick: str,
        *,
        user: str | None = None,
        realname: str | None = None,
        tls: bool = False,
        tls_insecure: bool = False,
        web_token: str | None = None,
    ) -> None:
        self._inner = _FreeqClient(
            server_addr,
            nick,
            user=user,
            realname=realname,
            tls=tls,
            tls_insecure=tls_insecure,
            web_token=web_token,
        )

    @property
    def nick(self) -> str:
        return self._inner.nick

    @property
    def server_addr(self) -> str:
        return self._inner.server_addr

    def connect(self) -> None:
        self._inner.connect()

    def disconnect(self) -> None:
        self._inner.disconnect()

    def join(self, channel: str) -> None:
        self._inner.join(channel)

    def send_message(self, target: str, text: str) -> None:
        self._inner.send_message(target, text)

    def history_latest(self, target: str, count: int = 50) -> None:
        self._inner.history_latest(target, count)

    def history_before(self, target: str, msgid: str, count: int = 50) -> None:
        """Request older messages before the given msgid."""
        self._inner.history_before(target, msgid, count)

    def send_reaction(self, target: str, emoji: str, msgid: str | None = None) -> None:
        """Send an emoji reaction to a target (channel or user).
        
        Uses +reply tag to match web client convention.
        Server broadcasts TAGMSG to all clients with message-tags cap.
        """
        # TAGMSG format: @+react=emoji;+reply=msgid TAGMSG target
        tags = f"+react={emoji}"
        if msgid:
            tags += f";+reply={msgid}"
        self._inner.raw(f"@{tags} TAGMSG {target}")

    def edit_message(self, target: str, new_text: str, msgid: str) -> None:
        """Edit an existing message.
        
        Uses +draft/edit tag per IRCv3 draft/edit specification.
        Server broadcasts the edited message to all clients.
        """
        # PRIVMSG format: @+draft/edit=msgid PRIVMSG target :new_text
        tags = f"+draft/edit={msgid}"
        self._inner.raw(f"@{tags} PRIVMSG {target} :{new_text}")

    def raw(self, line: str) -> None:
        self._inner.raw(line)

    def set_nick(self, nick: str) -> None:
        self._inner.set_nick(nick)

    def quit(self, message: str | None = None) -> None:
        self._inner.quit(message)

    def reconnect_with_web_token(self, web_token: str) -> None:
        self._inner.reconnect_with_web_token(web_token)

    def poll_event(self, timeout_ms: int = 0) -> dict[str, Any] | None:
        payload = self._inner.poll_event_json(timeout_ms)
        if payload is None:
            return None
        return json.loads(payload)


class FreeqAuthBroker:
    def __init__(self, shared_secret: str, *, freeq_server_url: str | None = None) -> None:
        self._inner = _FreeqAuthBroker(shared_secret, freeq_server_url=freeq_server_url)

    @property
    def base_url(self) -> str:
        return self._inner.base_url

    def start_login(self, handle: str) -> dict[str, Any]:
        return json.loads(self._inner.start_login(handle))

    def poll_auth_result(self, session_id: str) -> dict[str, Any] | None:
        payload = self._inner.poll_auth_result_json(session_id)
        if payload is None:
            return None
        return json.loads(payload)


class BrokerAuthFlow:
    def __init__(self, broker_url: str = "https://auth.freeq.at") -> None:
        self.broker_url = broker_url.rstrip("/")
        self._servers: dict[str, ThreadingHTTPServer] = {}
        self._results: dict[str, dict[str, Any]] = {}

    @property
    def base_url(self) -> str:
        return self.broker_url

    def start_login(self, handle: str) -> dict[str, Any]:
        server = ThreadingHTTPServer(("127.0.0.1", 0), self._make_handler())
        session_id = f"{server.server_port}-{handle}"
        server.session_id = session_id  # type: ignore[attr-defined]
        server.results = self._results  # type: ignore[attr-defined]
        callback_url = f"http://127.0.0.1:{server.server_port}/oauth/callback"
        url = (
            f"{self.broker_url}/auth/login"
            f"?handle={quote(handle)}"
            f"&return_to={quote(callback_url)}"
        )
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self._servers[session_id] = server
        return {"session_id": session_id, "url": url}

    def poll_auth_result(self, session_id: str) -> dict[str, Any] | None:
        result = self._results.pop(session_id, None)
        if result is None:
            return None
        server = self._servers.pop(session_id, None)
        if server is not None:
            server.shutdown()
            server.server_close()
        return result

    def refresh_session(self, broker_token: str) -> dict[str, Any] | None:
        request = Request(
            f"{self.broker_url}/session",
            data=json.dumps({"broker_token": broker_token}).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urlopen(request, timeout=10) as response:
            return json.loads(response.read().decode("utf-8"))

    def _make_handler(self) -> type[BaseHTTPRequestHandler]:
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802
                parsed = urlparse(self.path)
                if parsed.path == "/oauth/complete":
                    self._handle_complete(parsed.query)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write(
                    b"""<!DOCTYPE html><html><body style="background:#1e1e2e;color:#cdd6f4;font-family:sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0"><div id="msg" style="text-align:center"><h1>Completing authentication...</h1></div><script>var h=window.location.hash;if(h.startsWith('#oauth=')){fetch('/oauth/complete?oauth='+encodeURIComponent(h.slice(7))).then(function(){document.getElementById('msg').innerHTML='<h1>Authenticated!</h1><p>You can close this tab and return to freeq.</p>';});}else{document.getElementById('msg').innerHTML='<h1>Authentication failed</h1><p>No OAuth data received.</p>';}</script></body></html>"""
                )

            def log_message(self, format: str, *args: object) -> None:
                return

            def _handle_complete(self, query: str) -> None:
                params = parse_qs(query)
                oauth_payload = params.get("oauth", [None])[0]
                result: dict[str, Any]
                if oauth_payload is None:
                    result = {"error": "missing oauth payload"}
                else:
                    payload = oauth_payload.replace("-", "+").replace("_", "/")
                    padding = "=" * ((4 - len(payload) % 4) % 4)
                    decoded = base64.b64decode(payload + padding)
                    result = json.loads(decoded.decode("utf-8"))
                self.server.results[self.server.session_id] = result  # type: ignore[attr-defined]
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.end_headers()
                self.wfile.write(b"OK")

        return Handler
