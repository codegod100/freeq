#[tokio::main]
async fn main() {
    if let Err(err) = freeq_auth_broker::run_from_env().await {
        eprintln!("{err}");
        std::process::exit(1);
    }
}
