import Foundation
import Observation

/// The things copied, pinned ones first and each group newest first. Knows nothing
/// about the pasteboard or the island: it keeps the list in order and in bounds.
@MainActor
@Observable
final class ClipboardHistory {
    private(set) var items: [ClipboardItem] = []

    /// How many unpinned items are kept; the oldest go first. Pinned items are kept
    /// until they are unpinned or removed, and do not count.
    var limit: Int {
        didSet {
            guard limit != oldValue else { return }
            if trim() { onChange() }
        }
    }

    /// Called after every change to `items`.
    @ObservationIgnored var onChange: () -> Void = {}
    /// Bumped by `clear`, so a picture still being made when the history is cleared
    /// (the Mac locking as it is copied) does not arrive after it.
    @ObservationIgnored private(set) var generation = 0

    init(limit: Int = ClipboardPrefs.defaultLimit) {
        self.limit = max(1, limit)
    }

    /// The newest items by when they were copied, pinned or not, for the home tile.
    func recent(_ count: Int) -> [ClipboardItem] {
        Array(items.sorted { $0.copiedAt > $1.copiedAt }.prefix(count))
    }

    func item(id: UUID) -> ClipboardItem? {
        items.first { $0.id == id }
    }

    // MARK: Changes

    /// Adds something copied. Copied again, it moves back to the top (of the pinned
    /// ones, if pinned) as the same item, from the app it was copied from this time.
    /// Returns the item's id.
    @discardableResult
    func record(_ content: ClipboardContent, source: ClipboardSource?, at date: Date = Date()) -> UUID {
        let id: UUID
        if let index = items.firstIndex(where: { $0.content.isSame(as: content) }) {
            items[index].content = content
            items[index].source = source ?? items[index].source
            items[index].copiedAt = date
            id = items[index].id
        } else {
            let item = ClipboardItem(content: content, source: source, copiedAt: date)
            items.append(item)
            id = item.id
        }
        sort()
        trim()
        onChange()
        return id
    }

    /// The item was put back on the clipboard, which makes it the latest thing copied.
    func touch(_ id: UUID, at date: Date = Date()) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].copiedAt = date
        sort()
        onChange()
    }

    func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].isPinned != pinned else { return }
        items[index].isPinned = pinned
        sort()
        // Unpinned, an old item may now be past the limit.
        trim()
        onChange()
    }

    func remove(_ id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        onChange()
    }

    /// Empties the history, pinned items too unless `keepingPinned`.
    func clear(keepingPinned: Bool) {
        generation &+= 1
        let next = keepingPinned ? items.filter(\.isPinned) : []
        guard next.count != items.count else { return }
        items = next
        onChange()
    }

    /// Empties the history without a word, for a feature that has stopped: nothing is
    /// written, and nothing is told.
    func forget() {
        generation &+= 1
        items = []
    }

    /// Adds items read back from disk behind any copied since launch, leaving out ones
    /// copied again meanwhile.
    func merge(saved: [ClipboardItem]) {
        let fresh = saved.filter { old in !items.contains { $0.id == old.id || $0.content.isSame(as: old.content) } }
        guard !fresh.isEmpty else { return }
        items.append(contentsOf: fresh)
        sort()
        trim()
        onChange()
    }

    /// Replaces the whole list, for previews' sample histories.
    func replace(with items: [ClipboardItem]) {
        self.items = items
        sort()
        trim()
        onChange()
    }

    // MARK: Order

    private func sort() {
        items.sort { a, b in
            a.isPinned != b.isPinned ? a.isPinned : a.copiedAt > b.copiedAt
        }
    }

    /// Drops unpinned items past the limit, oldest first, and then unpinned pictures,
    /// oldest first, while the pictures kept come to more than
    /// `ClipboardLimits.allPicturesBytes`. Returns whether any went.
    @discardableResult
    private func trim() -> Bool {
        var unpinned = 0
        var kept = items.filter { item in
            guard !item.isPinned else { return true }
            unpinned += 1
            return unpinned <= limit
        }
        var pictureBytes = kept.reduce(0) { total, item in
            if case .image(let image) = item.content { return total + image.data.count }
            return total
        }
        while pictureBytes > ClipboardLimits.allPicturesBytes,
              let oldest = kept.lastIndex(where: { !$0.isPinned && $0.content.isImage }),
              case .image(let image) = kept[oldest].content {
            pictureBytes -= image.data.count
            kept.remove(at: oldest)
        }
        guard kept.count != items.count else { return false }
        items = kept
        return true
    }
}

/// The feature's preference keys, shared by the feature and its settings. Unset keys
/// read as their defaults, the same ones the settings controls declare.
enum ClipboardPrefs {
    static let limit = "clipboard.limit"
    static let keepHistory = "clipboard.keepHistory"
    static let clearOnLock = "clipboard.clearOnLock"

    static let defaultLimit = 12
    static let limits = [6, 12, 20, 30, 50]

    static var currentLimit: Int {
        let value = UserDefaults.standard.object(forKey: limit) as? Int ?? defaultLimit
        return min(max(value, 1), limits.last ?? defaultLimit)
    }

    static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    static var keepsHistory: Bool { bool(keepHistory, default: false) }
}
