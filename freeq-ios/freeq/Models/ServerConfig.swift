import Foundation

/// Server + auth-broker config, resolved from `IRC_SERVER` / `AUTH_BROKER_BASE`
/// (a scheme env var or an Info.plist build setting); defaults to freeq.at.
/// Point a build at another deployment (zerosum, a local instance) by setting
/// those two values — no source edits, no per-host branch.
struct ServerConfig {
    /// IRC server host:port — used as the TCP fallback when WebSocket can't
    /// be reached. Many cellular / captive-portal / corporate networks block
    /// raw 6667, which is why we prefer the WebSocket URL below.
    static let ircServer: String = configValue("IRC_SERVER") ?? "irc.freeq.at:6667"

    /// Auth broker base. freeq.at uses a standalone broker (`auth.freeq.at`);
    /// embedded-broker deployments (e.g. zerosum) set this to their own
    /// server origin.
    static let authBrokerBase: String = configValue("AUTH_BROKER_BASE") ?? "https://auth.freeq.at"

    /// Host portion of `ircServer`, without the port.
    static var host: String { ircServer.components(separatedBy: ":").first ?? ircServer }

    /// Primary IRC transport — same WebSocket endpoint the web client uses.
    /// Lives on port 443, so it traverses every firewall that allows HTTPS.
    static var wssServer: String { "wss://\(host)/irc" }

    /// HTTPS API base URL.
    static var apiBaseUrl: String { "https://\(host)" }

    /// MoQ SFU base URL — the dedicated QUIC/WebTransport listener on :8080,
    /// the same endpoint the web client and the `freeq-eliza` bot use.
    /// NOT the :443 reverse proxy: nginx proxies `/av/moq` there as an older
    /// `moq-lite-02` WebSocket that delivers audio in starved bursts. The
    /// :8080 listener speaks `moq-lite-03` over QUIC and is stable.
    static var sfuBaseUrl: String { "https://\(host):8080" }

    /// Stable identifier for the active deployment (server + broker). Lets the
    /// app notice when a build was retargeted at a different host so it can
    /// drop stale auth state — deployments share a bundle id and keychain.
    static var deploymentID: String { "\(ircServer)|\(authBrokerBase)" }

    /// Resolves a config value: scheme/process env var first (how the
    /// per-deployment Run schemes set it), then the Info.plist build setting.
    /// Returns nil for missing/empty values or an unsubstituted `$(VAR)`
    /// placeholder, so an un-wired build falls back to freeq.at.
    private static func configValue(_ key: String) -> String? {
        if let env = ProcessInfo.processInfo.environment[key], !env.isEmpty {
            return env
        }
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }
}
