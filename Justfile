set shell := ["bash", "-euxo", "pipefail", "-c"]

build-textual:
    nix build .#freeq-textual

run-textual *args:
    nix run .#freeq-textual -- {{args}}

dev-textual *args:
    PYTHONPATH=freeq-py/python${PYTHONPATH:+:${PYTHONPATH}} textual run --dev freeq_textual.dev:app -- {{args}}
