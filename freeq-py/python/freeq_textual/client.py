from __future__ import annotations

import json
from typing import Any

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

    def join(self, channel: str) -> None:
        self._inner.join(channel)

    def send_message(self, target: str, text: str) -> None:
        self._inner.send_message(target, text)

    def raw(self, line: str) -> None:
        self._inner.raw(line)

    def quit(self, message: str | None = None) -> None:
        self._inner.quit(message)

    def poll_event(self, timeout_ms: int = 0) -> dict[str, Any] | None:
        payload = self._inner.poll_event_json(timeout_ms)
        if payload is None:
            return None
        return json.loads(payload)
