set shell := ["bash", "-euxo", "pipefail", "-c"]

build-textual:
    nix build .#freeq-textual

run-textual *args:
    nix run .#freeq-textual -- {{args}}

# Hot reload dev mode (auto-restarts on Python file changes)
dev-textual *args:
    cd freeq-py && PYTHONPATH=python${PYTHONPATH:+:${PYTHONPATH}} textual run --dev freeq_textual.dev:app -- {{args}}

# Build and run with hot reload (if rust changes, rebuild first)
dev-textual-full *args:
    cd freeq-py && maturin develop && PYTHONPATH=python${PYTHONPATH:+:${PYTHONPATH}} textual run --dev freeq_textual.dev:app -- {{args}}
