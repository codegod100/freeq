set shell := ["bash", "-euxo", "pipefail", "-c"]

build-textual:
    nix build .#freeq-textual

run-textual *args:
    nix run .#freeq-textual -- {{args}}
