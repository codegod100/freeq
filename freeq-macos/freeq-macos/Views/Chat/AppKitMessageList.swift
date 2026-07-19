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

        deinit { NotificationCenter.default.removeObserver(self) }

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

            // When the width changes (window resize / panel toggle) each row is
            // pinned to a new fixed width, so RE-HOST them (reloadData) — a bare
            // `noteHeightOfRows` would re-measure stale content still framed at
            // the old width. Resize isn't a hot path, so a reload is fine; keep
            // the reader pinned to the bottom if they were there.
            table.onWidthChange = { [weak self, weak table] in
                guard let self, let table, table.numberOfRows > 0 else { return }
                let atBottom = self.isAtBottom()
                table.reloadData()
                if atBottom { self.scrollToBottom() }
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

            // Track scrolling so the hovered row's action bar can be clamped
            // into the viewport as content moves under the clip view.
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(clipBoundsChanged),
                name: NSView.boundsDidChangeNotification, object: scroll.contentView)

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
                // The reloaded SwiftUI content lays out asynchronously, so the
                // synchronous noteHeightOfRows above measures the PRE-change
                // height. A row that just gained a reaction badge would keep
                // its old (shorter) height and the pill would overflow into the
                // row below (the reaction-overlaps-next-message bug). The
                // per-cell intrinsic-size backstop can't cover this either — a
                // reload resets the cell's height baseline, so its first
                // post-layout measure is intentionally skipped. Re-measure the
                // changed rows once SwiftUI has laid the new content out.
                let changedIds = changed.map { newItems[$0].id }
                DispatchQueue.main.async { [weak self, weak tableView] in
                    guard let self, let tableView else { return }
                    let rows = IndexSet(changedIds.compactMap { id in
                        self.items.firstIndex(where: { $0.id == id })
                    })
                    if !rows.isEmpty {
                        tableView.noteHeightOfRows(withIndexesChanged: rows)
                    }
                }
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
            cell.host(content(for: items[row]), id: items[row].id)
            cell.clamp.overscroll = overscroll(forRow: row)
            return cell
        }

        /// How far `row`'s top has scrolled above the visible top edge (0 when
        /// fully below it). Drives the hover bar's downward clamp.
        private func overscroll(forRow row: Int) -> CGFloat {
            guard let table = tableView, let scroll = scrollView, row >= 0 else { return 0 }
            return max(0, scroll.documentVisibleRect.minY - table.rect(ofRow: row).minY)
        }

        /// Refresh every visible cell's clamp — called as the list scrolls.
        @objc private func clipBoundsChanged() {
            guard let table = tableView else { return }
            let range = table.rows(in: table.visibleRect)
            guard range.length > 0 else { return }
            for r in range.location..<(range.location + range.length) {
                guard let cell = table.view(atColumn: 0, row: r, makeIfNecessary: false)
                    as? HostingCellView else { continue }
                let value = overscroll(forRow: r)
                if abs(cell.clamp.overscroll - value) > 0.5 { cell.clamp.overscroll = value }
            }
        }

        /// The SwiftUI content for a row, with the app environment attached so
        /// hosted `@Environment(AppState.self)` / `@AppStorage` rows work.
        ///
        /// The row is pinned to a FIXED width (the table's current width). This
        /// is load-bearing, not cosmetic: chat rows use `maxWidth: .infinity`,
        /// so without a bound the hosting view's intrinsic *width* is infinite,
        /// and `.intrinsicContentSize` tries to install a content-size width
        /// constraint of ∞ — which `_makeOrUpdateContentSizeWidthConstraint`
        /// throws on (an uncaught NSException mid-layout → crash) the moment a
        /// row reflows before the cell's width is applied, e.g. when a reaction
        /// badge appears. A finite width makes both the width and the wrapped
        /// height valid.
        private func content(for item: Item) -> AnyView {
            let width = max(1, tableView?.bounds.width ?? 0)
            switch item {
            case .loadMore:
                let action = onLoadOlder
                return AnyView(LoadMoreRowContent(action: action).frame(width: width))
            case .entry(let row):
                let view = MessageTimelineRowContent(row: row)
                    .frame(width: width, alignment: .leading)
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
/// `NSHostingView` that reports when its intrinsic content size is invalidated.
/// SwiftUI-internal state — e.g. expanding a coalesced presence pill — changes
/// the content height without any model change the coordinator would catch, so
/// the table never re-measures the row and the taller content overflows the
/// cached row rect (clipped/overlapping, and the collapse control drifts out of
/// reach). The cell listens to this to note the row's new height.
private final class ReportingHostingView: NSHostingView<AnyView> {
    var onIntrinsicSizeChange: (() -> Void)?

    required init(rootView: AnyView) { super.init(rootView: rootView) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onIntrinsicSizeChange?()
    }
}

private final class HostingCellView: NSTableCellView {
    /// Per-cell clamp the coordinator updates on scroll so the hovered row's
    /// action bar stays inside the viewport. Injected into the hosted content.
    let clamp = RowClamp()
    private var hosting: ReportingHostingView?
    /// Last intrinsic height we synced to the table, so we only re-measure on a
    /// real change (not every layout pass) and never loop.
    private var lastIntrinsicHeight: CGFloat = -1
    private var heightSyncScheduled = false
    /// The row id currently hosted, so we can tell a scroll-reuse (different
    /// message) apart from a reload-in-place of the SAME row.
    private var currentItemId: String?

    func host(_ view: AnyView, id: String) {
        // Only reset the height baseline when this cell is REUSED for a
        // different row (scroll recycling): then we skip its first post-layout
        // measure to avoid a spurious re-measure / scroll jump. When the SAME
        // row is reloaded in place (a reaction badge added/removed, an edit),
        // KEEP the baseline so the intrinsic-size backstop notices the height
        // change and re-measures the row — otherwise the taller content (the
        // reaction pill) overflows into the row below. This is timing-
        // independent: it fires on whatever layout pass SwiftUI finally settles
        // on, so it also covers rows whose neighbour is a taller reply row.
        if id != currentItemId {
            currentItemId = id
            lastIntrinsicHeight = -1
        }
        let rooted = AnyView(view.environment(clamp))
        // On hover: stop clipping the (taller-than-row) action bar and lift this
        // row's z above its neighbours so the overflow draws on top of them.
        clamp.onHoverChanged = { [weak self] hovering in
            guard let self else { return }
            self.wantsLayer = true
            self.layer?.masksToBounds = false
            if let rowView = self.superview {
                rowView.wantsLayer = true
                rowView.layer?.masksToBounds = false
                rowView.layer?.zPosition = hovering ? 1 : 0
            }
        }
        if let hosting {
            hosting.rootView = rooted
            return
        }
        let h = ReportingHostingView(rootView: rooted)
        h.onIntrinsicSizeChange = { [weak self] in self?.scheduleHeightSync() }
        h.wantsLayer = true
        h.layer?.masksToBounds = false
        h.translatesAutoresizingMaskIntoConstraints = false
        h.sizingOptions = [.intrinsicContentSize]
        addSubview(h)
        // Pin all four edges so width is fixed to the column (text wraps at
        // the right point) and the row auto-sizes to content. The bottom pin
        // is REQUIRED-minus-one, not required: `.intrinsicContentSize`
        // installs a required content-size height constraint, and when a row
        // grows (e.g. a reaction badge appears) a required bottom pin becomes
        // momentarily unsatisfiable and AppKit throws an uncaught NSException
        // mid-layout (crash). At priority 999 the bottom yields to the
        // intrinsic height during that transient instead of throwing, while
        // still hugging content in the steady state.
        let bottom = h.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottom.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: leadingAnchor),
            h.trailingAnchor.constraint(equalTo: trailingAnchor),
            h.topAnchor.constraint(equalTo: topAnchor),
            bottom,
        ])
        hosting = h
    }

    /// When the hosted SwiftUI content changes intrinsic height (e.g. a
    /// coalesced presence pill expands/collapses), tell the table to re-measure
    /// THIS row so it grows/shrinks to fit instead of clipping the new content.
    /// Deferred + de-duped so we never mutate the table mid-layout or loop.
    private func scheduleHeightSync() {
        guard !heightSyncScheduled else { return }
        heightSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.heightSyncScheduled = false
            guard let h = self.hosting else { return }
            let newHeight = h.intrinsicContentSize.height
            guard newHeight >= 0, abs(newHeight - self.lastIntrinsicHeight) > 0.5 else { return }
            let hadBaseline = self.lastIntrinsicHeight >= 0
            self.lastIntrinsicHeight = newHeight
            // Skip the first measure (baseline set on host()); only real
            // subsequent changes trigger a re-measure.
            guard hadBaseline, let table = self.enclosingTableView() else { return }
            let row = table.row(for: self)
            guard row >= 0 else { return }
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
        }
    }

    private func enclosingTableView() -> NSTableView? {
        var view: NSView? = superview
        while let current = view {
            if let table = current as? NSTableView { return table }
            view = current.superview
        }
        return nil
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
