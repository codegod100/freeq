from __future__ import annotations

import os

from .bootstrap import build_app


def build_dev_app():
    return build_app(
        server=os.environ.get("FREEQ_SERVER", "irc.freeq.at:6697"),
        nick=os.environ.get("FREEQ_NICK", "textual"),
        channel=os.environ.get("FREEQ_CHANNEL"),
        auth_handle=os.environ.get("FREEQ_AUTH_HANDLE"),
        broker_url=os.environ.get("FREEQ_BROKER_URL", "https://auth.freeq.at"),
        session_path=os.environ.get("FREEQ_SESSION_PATH"),
        config_path=os.environ.get("FREEQ_CONFIG_PATH"),
        freeq_server_url=os.environ.get("FREEQ_SERVER_URL"),
        broker_shared_secret=os.environ.get("BROKER_SHARED_SECRET"),
        web_token=os.environ.get("FREEQ_WEB_TOKEN"),
        tls=os.environ.get("FREEQ_TLS", "").lower() in {"1", "true", "yes"},
        tls_insecure=os.environ.get("FREEQ_TLS_INSECURE", "").lower() in {"1", "true", "yes"},
    )


app = build_dev_app()
