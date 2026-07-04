import AppKit
import SwiftUI

/// AppKit-backed message list — the Phase 2 replacement for the SwiftUI
/// `LazyVStack` (see `SPIKE-MESSAGE-LIST.md`).
///
/// **Why AppKit.** The spike proved the `LazyVStack` misses the plan's <1%
/// main-thread hitch budget by 40–100× under two demo-critical loads: any
/// `scrollTo` across a large list (it forces layout of everything in between)
/// and streaming edits (every in-place mutation re-diffs the whole 10k-row
/// `ForEach`). A view-based `NSTableView` fixes both structurally: it lays out
/// only the rows on screen (row reuse), and it lets us reload *exactly* the
/// rows that changed rather than re-evaluating the world.
///
/// **Why NSTableView (not SwiftUI `List` or NSCollectionView).** The spike's
/// decision section ranks a full `NSTableView` + `NSHostingView` rows highest
/// for the control it gives over the three things a chat list lives or dies on:
/// bottom-anchoring, prepend-without-jump (history back-fill), and per-row
/// invalidation. SwiftUI `List` hides the scroll machinery we need; a
/// collection view is overkill for a single vertical column. So: a view-based,
/// single-column `NSTableView` with self-sizing row heights, each row hosting
/// the *unchanged* SwiftUI row content via `NSHostingView` — every visual
/// (avatars, badges, reactions, block markdown, media, tombstones, separators)
/// is reused verbatim, only the container changes.
///
/// **How updates stay cheap.** The enclosing `MessageListView` body rebuilds
/// the grouped `[RowModel]` on every observed change and hands it here. The
/// coordinator diffs it against the current rows *by id* and applies a minimal
/// mutation: structural inserts/removes for new/gone messages, and a targeted
/// `reloadData(forRowIndexes:)` for rows whose content changed
/// (edit/delete/reaction/header-flip). A streaming edit therefore reloads one
/// row, not ten thousand.
struct AppKitMessageListView: NSViewRepresentable {
    let rows: [RowModel]
    /// Active channel name. A change means a channel switch → full reload +
    /// snap to bottom (no animation), never a diff of unrelated content.
    let channelToken: String
    /// `appState.scrollToMessageId` — a non-nil change scrolls that row to
    /// centre (jump-to-message, reply navigation, history search).
    let scrollTarget: String?
    /// Compact-mode flag. A change re-measures every row (heights differ).
    let compactToken: Bool
    let showLoadMore: Bool
    let appState: AppState
    let onLoadOlder: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.apply(self)
    }

    // MARK: Coordinator

    /// Owns the table, the backing item array, and all scroll/diff logic.
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        /// A table row: either the sticky "load older" affordance or a message.
        enum Item: Equatable {
            case loadMore
            case entry(RowModel)

            var id: String {
                switch self {
                case .loadMore: return "__loadmore"
                case .entry(let r): return r.id
                }
            }
        }

        private var scrollView: NSScrollView!
        private var tableView: ChatTableView!

        private var items: [Item] = []
        private var appState: AppState?
        private var onLoadOlder: () -> Void = {}

        // Change-detection tokens so we only react to real transitions.
        private var lastChannelToken: String?
        private var lastScrollTarget: String?
        private var lastCompactToken: Bool?

        // Above this many structural changes we reload wholesale instead of
        // animating thousands of individual row inserts (e.g. a #stress bulk
        // injection or first paint of a large channel).
        private let bulkThreshold = 400

        private let cellIdentifier = NSUserInterfaceItemIdentifier("freeq.msgcell")

        func makeScrollView() -> NSScrollView {
            let table = ChatTableView()
            table.dataSource = self
            table.delegate = self
            table.headerView = nil
            table.backgroundColor = .clear
            table.selectionHighlightStyle = .none
            table.usesAutomaticRowHeights = true
            table.rowHeight = 44 // fallback estimate before a row self-sizes
            table.intercellSpacing = NSSize(width: 0, height: 0)
            table.style = .plain
            table.gridStyleMask = []
            table.allowsColumnResizing = false
            table.allowsColumnReordering = false
            table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("freeq.msgcol"))
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)

            // When the width changes (window resize / panel toggle) SwiftUI row
            // heights change too; invalidate them so the table re-measures.
            table.onWidthChange = { [weak self, weak table] in
                guard let self, let table, table.numberOfRows > 0 else { return }
                table.noteHeightOfRows(withIndexesChanged:
                    IndexSet(integersIn: 0..<table.numberOfRows))
            }

            let scroll = NSScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = false
            scroll.drawsBackground = false
            scroll.backgroundColor = .clear
            scroll.automaticallyAdjustsContentInsets = false
            // Breathing room: matches the legacy list's top padding + bottom
            // spacer so the last row never hugs the compose divider.
            scroll.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 12, right: 0)

            self.scrollView = scroll
            self.tableView = table
            return scroll
        }

        // MARK: Apply an update from SwiftUI

        func apply(_ parent: AppKitMessageListView) {
            self.appState = parent.appState
            self.onLoadOlder = parent.onLoadOlder

            var newItems: [Item] = []
            newItems.reserveCapacity(parent.rows.count + 1)
            if parent.showLoadMore { newItems.append(.loadMore) }
            newItems.append(contentsOf: parent.rows.map(Item.entry))

            let channelChanged = parent.channelToken != lastChannelToken
            let compactChanged = lastCompactToken != nil && parent.compactToken != lastCompactToken
            lastChannelToken = parent.channelToken
            lastCompactToken = parent.compactToken

            if channelChanged || items.isEmpty || newItems.isEmpty {
                // New channel (or first/last paint): reload wholesale and snap
                // to the bottom with no animation — never a visible top→bottom
                // sweep, never a diff against an unrelated channel's messages.
                items = newItems
                tableView.reloadData()
                tableView.layoutSubtreeIfNeeded()
                scrollToBottom()
                handleScrollTarget(parent)
                return
            }

            if compactChanged {
                items = newItems
                let wasAtBottom = isAtBottom()
                tableView.reloadData()
                tableView.layoutSubtreeIfNeeded()
                if wasAtBottom { scrollToBottom() }
                handleScrollTarget(parent)
                return
            }

            // Same channel: capture scroll intent, apply the minimal diff, then
            // restore the viewport. Bottom-pin only if the reader was already at
            // the bottom (a new message must not yank a reader up from history).
            let wasAtBottom = isAtBottom()
            let anchor = captureTopAnchor()
            applyDiff(newItems)
            if wasAtBottom {
                scrollToBottom()
            } else if let anchor {
                restore(anchor)
            }
            handleScrollTarget(parent)
        }

        /// Diff `items → newItems` by id and mutate the table minimally.
        private func applyDiff(_ newItems: [Item]) {
            let oldItems = items
            let oldIds = oldItems.map(\.id)
            let newIds = newItems.map(\.id)

            var oldIndexById: [String: Int] = [:]
            oldIndexById.reserveCapacity(oldIds.count)
            for (i, id) in oldIds.enumerated() { oldIndexById[id] = i }

            let diff = newIds.difference(from: oldIds)
            items = newItems

            // Wholesale reload when the structural churn is large — animating
            // hundreds/thousands of row inserts would itself blow the budget.
            if diff.insertions.count + diff.removals.count > bulkThreshold {
                tableView.reloadData()
                tableView.layoutSubtreeIfNeeded()
                return
            }

            // Structural changes: remove (descending offsets) then insert
            // (ascending offsets) — the order `CollectionDifference` guarantees.
            if !diff.isEmpty {
                tableView.beginUpdates()
                for change in diff.removals {
                    if case let .remove(offset, _, _) = change {
                        tableView.removeRows(at: IndexSet(integer: offset), withAnimation: [])
                    }
                }
                for change in diff.insertions {
                    if case let .insert(offset, _, _) = change {
                        tableView.insertRows(at: IndexSet(integer: offset), withAnimation: [])
                    }
                }
                tableView.endUpdates()
            }

            // Content changes: rows present in both whose model differs
            // (edit / delete / reaction / header or separator flip). Reload just
            // those, and re-measure them in case the height changed.
            var changed = IndexSet()
            for (newIdx, item) in newItems.enumerated() {
                if let oldIdx = oldIndexById[item.id], oldItems[oldIdx] != item {
                    changed.insert(newIdx)
                }
            }
            if !changed.isEmpty {
                tableView.reloadData(forRowIndexes: changed,
                                     columnIndexes: IndexSet(integer: 0))
                tableView.noteHeightOfRows(withIndexesChanged: changed)
            }
        }

        // MARK: Scroll anchoring

        private func isAtBottom() -> Bool {
            guard let scrollView else { return true }
            let visible = scrollView.documentVisibleRect
            let contentHeight = tableView.bounds.height
            // Within the bottom inset counts as "at bottom".
            return visible.maxY >= contentHeight - 16
        }

        private func scrollToBottom() {
            guard !items.isEmpty else { return }
            tableView.scrollRowToVisible(items.count - 1)
        }

        private struct TopAnchor { let id: String; let delta: CGFloat }

        /// Remember the top-most visible message and its offset within the
        /// viewport, so a mid-list insert / history prepend can keep the same
        /// row visually pinned.
        private func captureTopAnchor() -> TopAnchor? {
            guard let scrollView else { return nil }
            let visible = scrollView.documentVisibleRect
            var rowIndex = tableView.row(at: NSPoint(x: 2, y: visible.minY + 1))
            // Skip the sticky load-more row as an anchor.
            if rowIndex >= 0, rowIndex < items.count, items[rowIndex].id == "__loadmore" {
                rowIndex += 1
            }
            guard rowIndex >= 0, rowIndex < items.count else { return nil }
            let rect = tableView.rect(ofRow: rowIndex)
            return TopAnchor(id: items[rowIndex].id, delta: rect.minY - visible.minY)
        }

        private func restore(_ anchor: TopAnchor) {
            guard let scrollView,
                  let idx = items.firstIndex(where: { $0.id == anchor.id }) else { return }
            let rect = tableView.rect(ofRow: idx)
            let viewportHeight = scrollView.contentView.bounds.height
            let maxY = max(0, tableView.bounds.height - viewportHeight)
            let targetY = min(max(0, rect.minY - anchor.delta), maxY)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private func handleScrollTarget(_ parent: AppKitMessageListView) {
            guard parent.scrollTarget != lastScrollTarget else { return }
            lastScrollTarget = parent.scrollTarget
            guard let id = parent.scrollTarget,
                  let idx = items.firstIndex(where: { $0.id == id }),
                  let scrollView else { return }
            let rect = tableView.rect(ofRow: idx)
            let viewportHeight = scrollView.contentView.bounds.height
            let maxY = max(0, tableView.bounds.height - viewportHeight)
            let targetY = min(max(0, rect.midY - viewportHeight / 2), maxY)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            // Clear the request after the flash highlight (MessageRow keys its
            // background tint off scrollToMessageId, and re-renders itself).
            let app = appState
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if app?.scrollToMessageId == id { app?.scrollToMessageId = nil }
            }
        }

        // MARK: NSTableViewDataSource / Delegate

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(_ tableView: NSTableView,
                       viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = (tableView.makeView(withIdentifier: cellIdentifier, owner: self)
                as? HostingCellView) ?? {
                let c = HostingCellView()
                c.identifier = cellIdentifier
                return c
            }()
            cell.host(content(for: items[row]))
            return cell
        }

        /// The SwiftUI content for a row, with the app environment attached so
        /// hosted `@Environment(AppState.self)` / `@AppStorage` rows work.
        private func content(for item: Item) -> AnyView {
            switch item {
            case .loadMore:
                let action = onLoadOlder
                return AnyView(LoadMoreRowContent(action: action))
            case .entry(let row):
                let view = MessageTimelineRowContent(row: row)
                if let appState {
                    return AnyView(view.environment(appState))
                }
                return AnyView(view)
            }
        }
    }
}

// MARK: - Hosting cell

/// A table cell whose entire content is a single `NSHostingView`, pinned to the
/// cell edges so the SwiftUI content's intrinsic height drives the (automatic)
/// row height. The hosting view is created once and its `rootView` swapped on
/// reuse — no per-reuse view-tree teardown.
private final class HostingCellView: NSTableCellView {
    private var hosting: NSHostingView<AnyView>?

    func host(_ view: AnyView) {
        if let hosting {
            hosting.rootView = view
            return
        }
        let h = NSHostingView(rootView: view)
        h.translatesAutoresizingMaskIntoConstraints = false
        // Let SwiftUI define the height; width is pinned to the cell (column).
        h.sizingOptions = [.intrinsicContentSize]
        addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: leadingAnchor),
            h.trailingAnchor.constraint(equalTo: trailingAnchor),
            h.topAnchor.constraint(equalTo: topAnchor),
            h.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        hosting = h
    }
}

// MARK: - Table subclass

/// `NSTableView` that keeps its single column the full width and reports width
/// changes so the coordinator can re-measure self-sizing rows.
final class ChatTableView: NSTableView {
    var onWidthChange: (() -> Void)?
    private var lastWidth: CGFloat = 0

    override func layout() {
        super.layout()
        if let column = tableColumns.first, abs(column.width - bounds.width) > 0.5 {
            column.width = bounds.width
        }
        if abs(bounds.width - lastWidth) > 0.5 {
            lastWidth = bounds.width
            // Defer so we don't invalidate heights mid-layout pass.
            DispatchQueue.main.async { [weak self] in self?.onWidthChange?() }
        }
    }
}
