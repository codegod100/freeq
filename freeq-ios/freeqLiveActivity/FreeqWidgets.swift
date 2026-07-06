import SwiftUI
import WidgetKit

// Home / lock-screen widgets. Data crosses from the app via SharedStore (App
// Group); rows deep-link back into the app with freeq://open?target=…, handled
// in freeqApp's onOpenURL. Compiles without the App Group provisioned — it
// just renders the placeholder/empty snapshot until the entitlement lands.

private struct UnreadEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedStore.Snapshot
}

private struct UnreadProvider: TimelineProvider {
    func placeholder(in context: Context) -> UnreadEntry {
        UnreadEntry(date: Date(), snapshot: .init(
            totalUnread: 3,
            topChannels: [.init(name: "#general", unread: 2), .init(name: "#freeq", unread: 1)],
            connected: true, updatedAt: Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping (UnreadEntry) -> Void) {
        completion(UnreadEntry(date: Date(), snapshot: SharedStore.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UnreadEntry>) -> Void) {
        // The app pushes reloads via WidgetCenter on unread change; this is a
        // safety-net refresh so the widget never sits stale for long.
        let entry = UnreadEntry(date: Date(), snapshot: SharedStore.read())
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

private func openURL(_ target: String) -> URL {
    var comps = URLComponents()
    comps.scheme = "freeq"
    comps.host = "open"
    comps.queryItems = [URLQueryItem(name: "target", value: target)]
    return comps.url ?? URL(string: "freeq://open")!
}

/// Small: total unread + connection dot. Tapping opens the app.
private struct UnreadSummaryView: View {
    let snapshot: SharedStore.Snapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .foregroundStyle(.tint)
                Spacer()
                Circle()
                    .fill(snapshot.connected ? .green : .secondary)
                    .frame(width: 8, height: 8)
            }
            Spacer()
            Text("\(snapshot.totalUnread)")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.5)
            Text(snapshot.totalUnread == 1 ? "unread" : "unread")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding()
    }
}

/// Medium: top channels with unread badges; each row deep-links.
private struct UnreadListView: View {
    let snapshot: SharedStore.Snapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("freeq").font(.headline)
                Spacer()
                if snapshot.totalUnread > 0 {
                    Text("\(snapshot.totalUnread)")
                        .font(.caption.bold())
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.tint, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            if snapshot.topChannels.isEmpty {
                Spacer()
                Text(snapshot.connected ? "All caught up" : "Not connected")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                ForEach(snapshot.topChannels.prefix(4)) { ch in
                    Link(destination: openURL(ch.name)) {
                        HStack {
                            Text(ch.name).font(.subheadline).lineLimit(1)
                            Spacer()
                            Text("\(ch.unread)")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
    }
}

private struct UnreadEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UnreadEntry

    var body: some View {
        Group {
            if family == .systemSmall {
                UnreadSummaryView(snapshot: entry.snapshot)
            } else {
                UnreadListView(snapshot: entry.snapshot)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(openURL(""))
    }
}

struct FreeqUnreadWidget: Widget {
    let kind = "FreeqUnreadWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UnreadProvider()) { entry in
            UnreadEntryView(entry: entry)
        }
        .configurationDisplayName("Unread")
        .description("Your unread messages and top channels.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
