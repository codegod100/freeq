genrule(
    name = "freeq-webui",
    srcs = glob([
        "freeq-webui/src/**/*.rs",
        "freeq-webui/Cargo.toml",
        "freeq-webui/templates/**/*",
        "freeq-webui/static/**/*",
        "*/Cargo.toml",
        "Cargo.toml",
        "Cargo.lock",
    ]) + [
        "//freeq-sdk:freeq_sdk_srcs",
        "//freeq-oauth:freeq_oauth_srcs",
        "//freeq-ssrf:freeq_ssrf_srcs",
        "//freeq-webui/third-party:vendor",
        "//:freeq-webui-client",
    ],
    cmd = """
        # Trim the workspace to the members we actually need so Cargo does not try to
        # load manifests for crates that are not included in the sandbox. Copy the
        # manifest first because in the sandbox it may be a symlink to the real file.
        cp Cargo.toml Cargo.toml.work
        python3 -c '
import re
with open("Cargo.toml.work") as f:
    text = f.read()
text = re.sub(
    r"members = \\[.*?\\]",
    "members = [\\\"freeq-webui\\\", \\\"freeq-sdk\\\", \\\"freeq-oauth\\\", \\\"freeq-ssrf\\\"]",
    text,
    flags=re.DOTALL,
)
with open("Cargo.toml.work", "w") as f:
    f.write(text)
'
        mv Cargo.toml.work Cargo.toml

        # Ensure path dependencies resolve to the Buck-provided source directories.
        ln -sfn freeq_sdk_srcs freeq-sdk
        ln -sfn freeq_oauth_srcs freeq-oauth
        ln -sfn freeq_ssrf_srcs freeq-ssrf
        # Copy WASM artifacts into the static directory so they are
        # available at runtime. The WASM client genrule outputs a `pkg`
        # directory next to this one in the sandbox.
        mkdir -p freeq-webui/static
        cp "$(location :freeq-webui-client)/freeq_webui_client.js" freeq-webui/static/
        cp "$(location :freeq-webui-client)/freeq_webui_client_bg.wasm" freeq-webui/static/

        # Build into a sandbox-local target dir so Cargo never touches the
        # real workspace's Cargo.lock or target/ via the symlink.
        cd freeq-webui
        CARGO_TARGET_DIR="$PWD/../.buck-target" cargo build --release --bin freeq-webui
        cd ..
        cp .buck-target/release/freeq-webui "$OUT"
    """,
    out = "freeq-webui",
    executable = True,
    visibility = ["PUBLIC"],
)

# Build the WASM client crate. wasm-pack handles cross-compilation to
# wasm32-unknown-unknown, runs wasm-bindgen, and emits a JS shim that
# initialises the .wasm module. The output directory becomes the `out`
# directory for the genrule, with `freeq_webui_client.js` and
# `freeq_webui_client_bg.wasm` at the top.
genrule(
    name = "freeq-webui-client",
    srcs = glob([
        "freeq-webui-client/src/**/*.rs",
        "freeq-webui-client/Cargo.toml",
        "freeq-webui-client/build.sh",
    ]),
    cmd = """
        set -euo pipefail
        bash freeq-webui-client/build.sh
    """,
    out = "pkg",
    visibility = ["PUBLIC"],
)
