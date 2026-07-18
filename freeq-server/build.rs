use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=../.git/HEAD");
    println!("cargo:rerun-if-changed=../.git/refs/heads");
    // Embed git commit hash at build time
    let output = Command::new("git")
        .args(["rev-parse", "--short", "HEAD"])
        .output();
    let hash = match output {
        Ok(o) => String::from_utf8_lossy(&o.stdout).trim().to_string(),
        Err(_) => "unknown".to_string(),
    };
    println!("cargo:rustc-env=GIT_HASH={hash}");
}
