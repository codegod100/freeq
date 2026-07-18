import AppKit
import UniformTypeIdentifiers

/// macOS Share Extension: "Send to freeq" from any app's Share menu. Pulls
/// the shared text and/or URL from the item providers and opens the host app
/// via the `freeq://share` URL scheme (text + links fit in a URL, so no
/// app-group container is needed — this works under ad-hoc signing). The
/// host app pre-fills its quick-send panel with the payload.
///
/// Images/files aren't handled here yet: they exceed a URL and would need a
/// shared app-group container (which needs proper provisioning) — tracked as
/// a follow-up.
final class ShareViewController: NSViewController {

    override func loadView() {
        // No UI of our own — grab the content and hand off immediately.
        view = NSView(frame: .zero)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        Task { await handleShare() }
    }

    private func handleShare() async {
        var text: String?
        var link: String?

        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    if let url = try? await provider.loadItem(
                        forTypeIdentifier: UTType.url.identifier) as? URL {
                        link = url.absoluteString
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    if let s = try? await provider.loadItem(
                        forTypeIdentifier: UTType.plainText.identifier) as? String {
                        text = s
                    }
                }
            }
            // The item's own attributedContentText covers selected-text shares
            // that don't surface a plain-text attachment.
            if text == nil, let s = item.attributedContentText?.string, !s.isEmpty {
                text = s
            }
        }

        if let url = shareURL(text: text, link: link) {
            NSWorkspace.shared.open(url)
        }
        complete()
    }

    /// Build freeq://share?text=…&url=… — mirrors ShareURL.make in the app.
    private func shareURL(text: String?, link: String?) -> URL? {
        let hasText = !(text ?? "").isEmpty
        let hasLink = !(link ?? "").isEmpty
        guard hasText || hasLink else { return nil }
        var comps = URLComponents()
        comps.scheme = "freeq"
        comps.host = "share"
        var items: [URLQueryItem] = []
        if hasText { items.append(URLQueryItem(name: "text", value: text)) }
        if hasLink { items.append(URLQueryItem(name: "url", value: link)) }
        comps.queryItems = items
        return comps.url
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
