import Foundation

/// Parses the `freeq://share?…` URL the Share Extension (and any automation
/// or agent) opens to hand content to the running app. Text and links fit in
/// a URL, so this path needs no app-group container and works under ad-hoc
/// signing. Shape:
///
///     freeq://share?text=<body>&url=<link>&channel=<target>
///
/// `text` and `url` are combined into one message body; `channel` is an
/// optional pre-selected target (else the user picks in the quick-send panel).
enum ShareURL {
    struct Payload: Equatable {
        let body: String
        let target: String?
    }

    static func parse(_ url: URL) -> Payload? {
        guard url.scheme == "freeq", url.host == "share" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        let text = value("text")
        let link = value("url")
        let body = [text, link].compactMap { $0 }.joined(separator: " ")
        guard !body.isEmpty else { return nil }
        return Payload(body: body, target: value("channel"))
    }

    /// Build a share URL (used by the extension). Encodes safely. Returns nil
    /// when there's no body content — a channel with nothing to say is not a
    /// shareable payload (and `parse` would reject it anyway).
    static func make(text: String?, link: String?, channel: String?) -> URL? {
        let hasText = !(text ?? "").isEmpty
        let hasLink = !(link ?? "").isEmpty
        guard hasText || hasLink else { return nil }

        var comps = URLComponents()
        comps.scheme = "freeq"
        comps.host = "share"
        var items: [URLQueryItem] = []
        if hasText { items.append(URLQueryItem(name: "text", value: text)) }
        if hasLink { items.append(URLQueryItem(name: "url", value: link)) }
        if let channel, !channel.isEmpty { items.append(URLQueryItem(name: "channel", value: channel)) }
        comps.queryItems = items
        return comps.url
    }
}
