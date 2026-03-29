from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

from .app import FreeqTextualApp
from .client import BrokerAuthFlow, FreeqAuthBroker, FreeqClient


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Textual TUI for freeq backed by freeq-sdk")
    parser.add_argument("--server", default="irc.freeq.at:6697", help="IRC server host:port")
    parser.add_argument("--nick", default="textual", help="nickname to use")
    parser.add_argument("--channel", help="channel to auto-join")
    parser.add_argument("--auth-handle", help="ATProto handle to begin browser auth on startup")
    parser.add_argument("--broker-url", default=os.environ.get("FREEQ_BROKER_URL", "https://auth.freeq.at"), help="external auth broker base URL")
    parser.add_argument("--session-path", default=os.environ.get("FREEQ_SESSION_PATH"), help="path to cached broker session JSON")
    parser.add_argument("--config-path", default=os.environ.get("FREEQ_CONFIG_PATH"), help="path to UI config JSON")
    parser.add_argument("--freeq-server-url", default=os.environ.get("FREEQ_SERVER_URL"), help="freeq server base URL for broker web-token minting")
    parser.add_argument("--broker-shared-secret", default=os.environ.get("BROKER_SHARED_SECRET"), help="shared secret used by the embedded auth broker")
    parser.add_argument("--web-token", default=os.environ.get("FREEQ_WEB_TOKEN"), help="one-time web token for authenticated connect")
    parser.add_argument("--tls", action="store_true", help="connect with TLS")
    parser.add_argument(
        "--tls-insecure",
        action="store_true",
        help="skip TLS certificate verification",
    )
    return parser


def main() -> None:
    args = build_parser().parse_args()
    session_path = Path(args.session_path).expanduser() if args.session_path else Path.home() / ".config" / "freeq" / "freeq-textual-session.json"
    config_path = Path(args.config_path).expanduser() if args.config_path else Path.home() / ".config" / "freeq" / "freeq-textual-config.json"
    cached_auth = None
    ui_config = None
    if session_path.exists():
        try:
            cached_auth = json.loads(session_path.read_text())
        except Exception:  # noqa: BLE001
            cached_auth = None
    if config_path.exists():
        try:
            ui_config = json.loads(config_path.read_text())
        except Exception:  # noqa: BLE001
            ui_config = None
    client = FreeqClient(
        server_addr=args.server,
        nick=args.nick,
        tls=args.tls,
        tls_insecure=args.tls_insecure,
        web_token=args.web_token,
    )
    auth_broker = BrokerAuthFlow(args.broker_url) if args.broker_url else None
    if args.broker_shared_secret:
        auth_broker = FreeqAuthBroker(
            args.broker_shared_secret,
            freeq_server_url=args.freeq_server_url,
        )
    app = FreeqTextualApp(
        client=client,
        initial_channel=args.channel,
        auth_broker=auth_broker,
        auth_handle=args.auth_handle,
        session_path=session_path,
        cached_auth=cached_auth,
        config_path=config_path,
        ui_config=ui_config,
    )
    app.run()


if __name__ == "__main__":
    main()
