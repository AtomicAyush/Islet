import AppKit
import SwiftUI

/// A file as a drag carries it out of the island: the file itself, under its own name,
/// so Finder copies it, a mail becomes an attachment and an upload field takes it.
enum FileDrag {
    static func provider(for url: URL) -> NSItemProvider {
        let provider = NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL)
        provider.suggestedName = url.lastPathComponent
        return provider
    }
}

/// A file to drag out of the island, for a card that needs to know how the drag ended,
/// which `onDrag` never says. Laid over what stands for the file, it takes that view's
/// clicks: a click is `tapped`, and a drag carries the file itself, as Finder's own drags
/// do, which Finder copies, a mail takes as an attachment and an upload field takes.
struct FileDragSource: NSViewRepresentable {
    enum Phase: Equatable {
        case began
        /// Let go over something that took the file (`true`), or over nothing that did.
        case ended(dropped: Bool)
    }

    let url: URL
    let help: String
    let tapped: () -> Void
    let dragged: (Phase) -> Void

    func makeNSView(context: Context) -> SourceView {
        let view = SourceView(url: url)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: SourceView, context: Context) {
        view.url = url
        view.toolTip = help
        view.tapped = tapped
        view.dragged = dragged
    }

    final class SourceView: NSView, NSDraggingSource {
        var url: URL
        var tapped: () -> Void = {}
        var dragged: (Phase) -> Void = { _ in }
        /// The press a drag or a click may come of.
        private var press: NSEvent?
        /// Itself while a drag it began is under way, so the drag's end is heard even if
        /// the card has gone meanwhile.
        private var dragging: SourceView?

        /// How far the pointer moves with the button down before it counts as a drag.
        static let slop: CGFloat = 3

        init(url: URL) {
            self.url = url
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        // The panel never becomes key: the first click must count.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            press = event
        }

        override func mouseDragged(with event: NSEvent) {
            guard let press else { return }
            let start = press.locationInWindow, now = event.locationInWindow
            guard hypot(now.x - start.x, now.y - start.y) >= Self.slop else { return }
            self.press = nil
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(bounds, contents: NSWorkspace.shared.icon(forFile: url.path))
            dragging = self
            beginDraggingSession(with: [item], event: press, source: self)
            dragged(.began)
        }

        override func mouseUp(with event: NSEvent) {
            guard press != nil else { return }
            press = nil
            if bounds.contains(convert(event.locationInWindow, from: nil)) { tapped() }
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            ended(operation)
        }

        /// The drag is over: `operation` is what the place it was let go over did with the
        /// file, nothing if it took none.
        func ended(_ operation: NSDragOperation) {
            dragging = nil
            dragged(.ended(dropped: !operation.isEmpty))
        }
    }
}
