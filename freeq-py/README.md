# freeq-textual

Python `textual` TUI for freeq backed by the Rust `freeq-sdk` through `PyO3`.

## Build

```sh
cd freeq-py
maturin develop
```

## Run

```sh
freeq-textual --server 127.0.0.1:6667 --nick textual --channel '#freeq'
```

Current scope:

- guest connection via `freeq-sdk`
- join channels
- send messages
- poll SDK events into a `textual` UI

Not implemented yet:

- AT Protocol auth
- channel member list
- history pagination
- media, reactions, and rich message rendering
