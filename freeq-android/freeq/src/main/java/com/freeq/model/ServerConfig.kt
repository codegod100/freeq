package com.freeq.model

/** Central server configuration - change here to point to a different server */
object ServerConfig {
    /** IRC server host:port */
    var ircServer: String = "irc.freeq.at:6667"

    /** HTTPS API base URL (derived from ircServer) */
    val apiBaseUrl: String
        get() = "https://" + ircServer.substringBefore(":")
}
