# Freeq Textual - Product Requirements Document

## Overview

Freeq Textual is a Python TUI (Terminal User Interface) IRC client for the freeq chat network, built with the Textual framework and backed by a Rust SDK via PyO3 bindings.

## Project Structure

```
freeq-py/
├── python/freeq_textual/    # Python source code
│   ├── app.py                # Main application logic
│   ├── client.py             # PyO3 wrapper for Rust SDK
│   ├── bootstrap.py          # App factory with DI
│   ├── models.py             # Data classes
│   ├── formatting.py         # Message rendering
│   ├── components/         # Swappable UI components
│   └── widgets/              # Textual widgets
├── src/                      # Rust PyO3 bindings
├── tests/                    # Python test suite
├── spec/                     # Phoenix pipeline specs
│   ├── auth.md
│   ├── irc-client.md
│   ├── messaging.md
│   ├── threading.md
│   ├── ui-components.md
│   ├── integration.md
│   ├── avatar-fetching.md
│   └── reactions.md
├── pyproject.toml            # Python package config
└── Cargo.toml               # Rust package config
```

## Key Technologies

- **Textual**: Modern Python TUI framework
- **PyO3**: Rust-Python bindings
- **Rich**: Text rendering and formatting
- **freeq-sdk**: Rust IRC client library
- **AT Protocol**: Decentralized identity (Bluesky)

## Build System

- **maturin**: Builds and develops Python-Rust hybrid projects
- Build: `maturin develop`
- Run: `python -m freeq_textual --tls --channel '#test'`

## Testing

- Tests use Textual's `run_test()` async context
- FakeClient mock for IRC client
- Avatar support disabled in tests for consistent output

## Pipeline Targets

This project is configured for Phoenix pipeline code generation targeting:
- Python 3.12+
- Type hints and dataclasses
- Textual widget patterns
- Async/await patterns for TUI
