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
    ],
    cmd = """
        # Trim the workspace to the members we actually need so Cargo does not try to
        # load manifests for crates that are not included in the sandbox. Copy the
        # manifest first because in the sandbox it may be a symlink to the real file.
        cp Cargo.toml Cargo.toml.work
        # Break the symlink so Cargo writes its in-sandbox lockfile here, not
        # back into the real workspace via the symlink.
        cp Cargo.lock Cargo.lock.real
        mv Cargo.lock.real Cargo.lock
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
