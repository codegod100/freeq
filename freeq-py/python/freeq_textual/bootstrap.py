from __future__ import annotations

import json
from pathlib import Path

from .app import FreeqTextualApp
from .client import BrokerAuthFlow, FreeqAuthBroker, FreeqClient


def _read_json(path: Path) -> dict | None:
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text())
    except Exception:  # noqa: BLE001
        return None


def _default_session_path() -> Path:
    return Path.home() / ".config" / "freeq" / "freeq-textual-session.json"


def _default_config_path() -> Path:
    return Path.home() / ".config" / "freeq" / "freeq-textual-config.json"


def build_app(
    *,
    server: str,
    nick: str,
    channel: str | None = None,
    auth_handle: str | None = None,
    broker_url: str | None = "https://auth.freeq.at",
    session_path: str | Path | None = None,
    config_path: str | Path | None = None,
    freeq_server_url: str | None = None,
    broker_shared_secret: str | None = None,
    web_token: str | None = None,
    tls: bool = False,
    tls_insecure: bool = False,
) -> FreeqTextualApp:
    session_path_obj = Path(session_path).expanduser() if session_path else _default_session_path()
    config_path_obj = Path(config_path).expanduser() if config_path else _default_config_path()
    cached_auth = _read_json(session_path_obj)
    ui_config = _read_json(config_path_obj)

    client = FreeqClient(
        server_addr=server,
        nick=nick,
        tls=tls,
        tls_insecure=tls_insecure,
        web_token=web_token,
    )

    auth_broker = BrokerAuthFlow(broker_url) if broker_url else None
    if broker_shared_secret:
        auth_broker = FreeqAuthBroker(
            broker_shared_secret,
            freeq_server_url=freeq_server_url,
        )

    return FreeqTextualApp(
        client=client,
        initial_channel=channel,
        auth_broker=auth_broker,
        auth_handle=auth_handle,
        session_path=session_path_obj,
        cached_auth=cached_auth,
        config_path=config_path_obj,
        ui_config=ui_config,
    )
