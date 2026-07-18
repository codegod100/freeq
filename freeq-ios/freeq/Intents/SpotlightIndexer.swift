import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Pushes the user's joined channels and DM buffers into the system Spotlight
/// index so they show up in iOS-wide search. Tapping a result wakes the app
/// via NSUserActivity (see ContentView's `.onContinueUserActivity`).
enum SpotlightIndexer {
    static let domain = "at.freeq.ios.channels"

    /// Re-index everything currently in `appState`. Cheap to call after the
    /// channel/DM list changes — CoreSpotlight de-dups by uniqueIdentifier.
    static func reindex(_ appState: AppState) {
        let channelItems = appState.channels.map { ch -> CSSearchableItem in
            let attrs = CSSearchableItemAttributeSet(contentType: .text)
            attrs.title = ch.name
            attrs.contentDescription = ch.topic.isEmpty ? "freeq channel" : ch.topic
            attrs.keywords = ["freeq", "channel", ch.name]
            return CSSearchableItem(uniqueIdentifier: ch.name,
                                    domainIdentifier: domain,
                                    attributeSet: attrs)
        }
        let dmItems = appState.dmBuffers.map { dm -> CSSearchableItem in
            let attrs = CSSearchableItemAttributeSet(contentType: .text)
            attrs.title = "@\(dm.name)"
            attrs.contentDescription = "Direct message"
            attrs.keywords = ["freeq", "dm", "direct message", dm.name]
            return CSSearchableItem(uniqueIdentifier: dm.name,
                                    domainIdentifier: domain,
                                    attributeSet: attrs)
        }
        let items = channelItems + dmItems
        guard !items.isEmpty else { return }
        CSSearchableIndex.default().indexSearchableItems(items) { error in
            if let error {
                print("[spotlight] indexSearchableItems failed: \(error)")
            }
        }
    }

    /// Drop everything we previously indexed — used on logout.
    static func clear() {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain]) { error in
            if let error {
                print("[spotlight] delete failed: \(error)")
            }
        }
    }
}
