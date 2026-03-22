import Foundation

/// Central server configuration - change here to point to a different server
struct ServerConfig {
    /// IRC server host:port (default: production)
    static var ircServer: String = "irc.freeq.at:6667"

    /// HTTPS API base URL (derived from ircServer)
    static var apiBaseUrl: String {
        let host = ircServer.components(separatedBy: ":").first ?? ircServer
        return "https://\(host)"
    }
}
