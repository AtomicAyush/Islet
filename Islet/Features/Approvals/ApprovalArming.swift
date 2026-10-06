import AppKit
import Foundation

/// When a card's Allow may be taken, so a click meant for something else, made before
/// the card was read, or not made by a person at all, approves nothing:
///
/// 1. The card for this request has been wholly on screen for 0.6 seconds; after the
///    island opened by itself, 1 second, and the pointer must have come into the island
///    since it finished opening.
/// 2. The pointer came onto Allow after that, from outside it, as mouse movement says
///    (not hover, which a card appearing under a still pointer would set off), and has
///    rested there a quarter of a second. A pointer already on Allow when the card came,
///    or when Allow moved under it, must leave it and come back.
/// 3. All of the request has been seen: it fits, or its end has been scrolled into view.
/// 4. The click is a person's (`ApprovalClickCheck`), and no other app's window lies over
///    the card.
/// 5. The request is the one the button was made for, its file unchanged
///    (`ApprovalCenter.answer`).
///
/// Deny needs only rule 1. Times are `ProcessInfo.systemUptime`, as events carry.
struct ApprovalArming: Equatable, Sendable {
    static let onScreen: TimeInterval = 0.6
    static let onScreenAfterOpening: TimeInterval = 1
    static let rest: TimeInterval = 0.25

    enum Readiness: Equatable, Sendable {
        /// Allow may be taken.
        case armed
        /// Not yet: "Hold on Allow for a moment".
        case early
        /// The end of the request not seen: "Scroll to read it all".
        case unseen
    }

    let id: String
    let digest: String
    /// Whether the island opened by itself for this request.
    var openedByItself = false
    /// When the card was last wholly on screen from; `nil` while it is not.
    private(set) var shownSince: TimeInterval?
    /// When the island finished opening by itself.
    private(set) var openedAt: TimeInterval?
    /// When the pointer last came into the island.
    private(set) var enteredIslandAt: TimeInterval?
    /// Where the pointer is for Allow, and since when it came onto it from outside.
    enum Pointer: Equatable, Sendable {
        /// Nothing known yet: the card has only just come.
        case unknown
        case outside
        /// On Allow without having come onto it: there when the card came, or when Allow
        /// moved under it.
        case under
        /// Came onto Allow from outside it.
        case onAllow
    }
    private(set) var pointer = Pointer.unknown
    private(set) var enteredAllowAt: TimeInterval?
    var onAllow: Bool { pointer == .onAllow }
    private(set) var bodySeen = false

    init(id: String, digest: String, openedByItself: Bool = false) {
        self.id = id
        self.digest = digest
        self.openedByItself = openedByItself
    }

    /// The card came wholly on screen, or stopped being: collapsed, covered by another
    /// page, scrolled off, its display gone.
    mutating func shown(_ shown: Bool, at time: TimeInterval) {
        if shown {
            if shownSince == nil { shownSince = time }
        } else {
            shownSince = nil
        }
    }

    mutating func finishedOpening(at time: TimeInterval) { openedAt = time }

    mutating func pointerEnteredIsland(at time: TimeInterval) { enteredIslandAt = time }

    /// Where the pointer is, from mouse movement: only a pointer known to be outside
    /// Allow comes onto it.
    mutating func pointer(onAllow now: Bool, at time: TimeInterval) {
        switch (now, pointer) {
        case (false, _):
            pointer = .outside
            enteredAllowAt = nil
        case (true, .outside):
            pointer = .onAllow
            enteredAllowAt = time
        case (true, .unknown):
            pointer = .under
        case (true, _):
            break
        }
    }

    /// Allow was laid out, or moved, with the pointer on it and not moving: it has to
    /// leave and come back.
    mutating func pointerUnder() {
        if pointer == .unknown || pointer == .outside { pointer = .under }
    }

    mutating func seen(_ seen: Bool) { bodySeen = bodySeen || seen }

    /// When rule 1 holds from, `nil` while the card is not on screen.
    func shownLongEnoughFrom() -> TimeInterval? {
        guard let shownSince else { return nil }
        guard openedByItself else { return shownSince + Self.onScreen }
        var from = shownSince + Self.onScreenAfterOpening
        if let openedAt { from = max(from, openedAt) }
        return from
    }

    /// Rule 1, all Deny needs.
    func mayDeny(at time: TimeInterval) -> Bool {
        guard let from = shownLongEnoughFrom() else { return false }
        if openedByItself {
            guard let openedAt, let enteredIslandAt, enteredIslandAt >= openedAt else { return false }
        }
        return time >= from
    }

    /// Rules 1 to 3.
    func readiness(at time: TimeInterval) -> Readiness {
        guard bodySeen else { return .unseen }
        guard mayDeny(at: time), let from = shownLongEnoughFrom(), onAllow, let entered = enteredAllowAt,
              entered >= from, time - entered >= Self.rest
        else { return .early }
        return .armed
    }

    /// How long the card is on screen before VoiceOver or Switch Control may take Allow.
    static let onScreenAssisted: TimeInterval = 1

    /// Allow taken through VoiceOver or Switch Control, which reach the card's own
    /// buttons and never the drawn one, the whole request read out as the card's value:
    /// only with one of them on, and the card a second on screen (longer after the island
    /// opened by itself).
    func takeAssisted(at time: TimeInterval, assistiveOn: Bool) -> ApprovalClick? {
        guard assistiveOn, let shownSince else { return nil }
        let wait = openedByItself ? max(Self.onScreenAssisted, Self.onScreenAfterOpening) : Self.onScreenAssisted
        guard time - shownSince >= wait, time >= (openedAt ?? 0) else { return nil }
        return ApprovalClick(id: id, digest: digest)
    }

    /// Rules 1 to 4, at the click: a token for this request, or `nil`.
    func take(_ click: ApprovalClickCheck.Click, at time: TimeInterval,
              windowsAbove: (ApprovalClickCheck.Click) -> Bool = ApprovalClickCheck.othersOverlap) -> ApprovalClick? {
        guard readiness(at: time) == .armed, ApprovalClickCheck.isReal(click, now: time, windowsAbove: windowsAbove)
        else { return nil }
        return ApprovalClick(id: id, digest: digest)
    }
}

/// Proof that Allow was clicked for this request as `ApprovalArming` requires: only
/// this file can make one.
struct ApprovalClick: Equatable, Sendable {
    let id: String
    let digest: String

    fileprivate init(id: String, digest: String) {
        self.id = id
        self.digest = digest
    }
}

/// Whether a click on Allow was a person's.
enum ApprovalClickCheck {
    /// What is known of the click: the release, the press before it, where Allow was and
    /// over what part of the screen the card lies.
    struct Click {
        var up: Event
        var down: Event?
        var panelWindow: Int
        /// Allow's frame, in the panel window's coordinates.
        var allowFrame: CGRect
        /// The card's frame on screen, in Quartz's coordinates (origin top left).
        var cardOnScreen: CGRect
        /// The panel's window, for the windows above it.
        var panelWindowID: CGWindowID
    }

    /// The parts of an `NSEvent` the check reads.
    struct Event {
        var isMouseUp: Bool
        var isMouseDown: Bool
        var timestamp: TimeInterval
        var windowNumber: Int
        var location: CGPoint
        /// The process that posted it: 0 for one from the hardware.
        var sourcePID: Int64

        init(_ event: NSEvent) {
            isMouseUp = event.type == .leftMouseUp
            isMouseDown = event.type == .leftMouseDown
            timestamp = event.timestamp
            windowNumber = event.windowNumber
            location = event.locationInWindow
            sourcePID = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1
        }

        init(isMouseUp: Bool, isMouseDown: Bool, timestamp: TimeInterval, windowNumber: Int, location: CGPoint,
             sourcePID: Int64) {
            (self.isMouseUp, self.isMouseDown, self.timestamp) = (isMouseUp, isMouseDown, timestamp)
            (self.windowNumber, self.location, self.sourcePID) = (windowNumber, location, sourcePID)
        }
    }

    /// How old the release may be when it is acted on.
    static let freshness: TimeInterval = 0.1

    static func isReal(_ click: Click, now: TimeInterval, windowsAbove: (Click) -> Bool = othersOverlap) -> Bool {
        let up = click.up
        guard up.isMouseUp, abs(now - up.timestamp) <= freshness, up.windowNumber == click.panelWindow,
              click.allowFrame.contains(up.location), up.sourcePID == 0,
              let down = click.down, down.isMouseDown, down.windowNumber == click.panelWindow,
              click.allowFrame.contains(down.location), down.timestamp <= up.timestamp, down.sourcePID == 0
        else { return false }
        return !windowsAbove(click)
    }

    /// Whether another app's window, on screen above the panel, lies over the card: it
    /// could be drawing other words over the request.
    static func othersOverlap(_ click: Click) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements],
                                                       click.panelWindowID) as? [[String: Any]]
        else { return true }
        let own = Int(getpid())
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? Int) != own,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds)
            else { return false }
            return frame.intersects(click.cardOnScreen)
        }
    }
}
