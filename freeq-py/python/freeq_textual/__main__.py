from __future__ import annotations

import argparse
import os

from .bootstrap import build_app


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
    app = build_app(
        server=args.server,
        nick=args.nick,
        channel=args.channel,
        auth_handle=args.auth_handle,
        broker_url=args.broker_url,
        session_path=args.session_path,
        config_path=args.config_path,
        freeq_server_url=args.freeq_server_url,
        broker_shared_secret=args.broker_shared_secret,
        web_token=args.web_token,
        tls=args.tls,
        tls_insecure=args.tls_insecure,
    )
    app.run()


if __name__ == "__main__":
    main()
