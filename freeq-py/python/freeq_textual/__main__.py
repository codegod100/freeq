from __future__ import annotations

import argparse

from .app import FreeqTextualApp
from .client import FreeqClient


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Textual TUI for freeq backed by freeq-sdk")
    parser.add_argument("--server", default="127.0.0.1:6667", help="IRC server host:port")
    parser.add_argument("--nick", default="textual", help="nickname to use")
    parser.add_argument("--channel", help="channel to auto-join")
    parser.add_argument("--tls", action="store_true", help="connect with TLS")
    parser.add_argument(
        "--tls-insecure",
        action="store_true",
        help="skip TLS certificate verification",
    )
    return parser


def main() -> None:
    args = build_parser().parse_args()
    client = FreeqClient(
        server_addr=args.server,
        nick=args.nick,
        tls=args.tls,
        tls_insecure=args.tls_insecure,
    )
    app = FreeqTextualApp(client=client, initial_channel=args.channel)
    app.run()


if __name__ == "__main__":
    main()
