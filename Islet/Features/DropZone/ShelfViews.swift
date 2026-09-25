import AppKit
import QuickLookThumbnailing
import SwiftUI

/// The shelf on the home page: the files kept, newest first, ready to be dragged out.
struct ShelfHomeTile: View {
    let model: DropZoneModel

    var body: some View {
        let items = model.shelf.items

        VStack(alignment: .leading, spacing: 6) {
            // The tile's width depends on how many other widgets are up; the header
            // sheds words rather than truncate them.
            ViewThatFits(in: .horizontal) {
                header(count: items.count, titled: true, spelledClear: true)
                header(count: items.count, titled: true, spelledClear: false)
                header(count: items.count, titled: false, spelledClear: false)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(items) { item in
                        ShelfItemView(item: item, model: model)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: items.map(\.id))
        .onAppear { model.shelf.refresh() }
    }

    private func header(count: Int, titled: Bool, spelledClear: Bool) -> some View {
        HStack(spacing: 5) {
            Group {
                if titled {
                    Label("Shelf", systemImage: "tray.full.fill")
                } else {
                    Image(systemName: "tray.full.fill")
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(dropZoneYellow)
            .lineLimit(1)
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.55))
                .contentTransition(.numericText())
            Spacer(minLength: 4)
            ClearButton(spelled: spelledClear) { model.shelf.clear() }
        }
    }
}

/// One file on the shelf. Click to open it, drag it out to use it; it stays on the
/// shelf either way until it is removed.
private struct ShelfItemView: View {
    let item: ShelfItem
    let model: DropZoneModel
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        VStack(spacing: 3) {
            FileIcon(url: item.url, size: 36)
            Text(item.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(width: 60)
        .padding(.vertical, 4)
        .background(shape.fill(Color.white.opacity(isHovering ? 0.1 : 0)))
        .overlay(alignment: .topTrailing) {
            if isHovering {
                RemoveBadge { model.shelf.remove(item) }
                    .padding(2)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .contentShape(shape)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
        .onTapGesture { model.open(item) }
        .onDrag { item.dragProvider() }
        .contextMenu {
            Button("Open") { model.open(item) }
            Button("Show in Finder") { model.reveal(item) }
            Button("AirDrop") { model.share(item) }
            Divider()
            Button("Remove from Shelf") { model.shelf.remove(item) }
        }
        .help(item.name)
    }
}

private struct RemoveBadge: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 15, height: 15)
                .background(Circle().fill(Color(white: 0.32)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// “Clear” in a capsule, or just a cross in a circle where the tile is narrow.
private struct ClearButton: View {
    let spelled: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if spelled {
                    Text("Clear")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7)
                } else {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .heavy))
                        .frame(width: 16)
                }
            }
            .foregroundStyle(.white.opacity(isHovering ? 0.95 : 0.7))
            .frame(height: 16)
            .background(Capsule().fill(Color.white.opacity(isHovering ? 0.2 : 0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Clear the shelf")
    }
}

extension ShelfItem {
    /// The file as a drag carries it out of the island.
    func dragProvider() -> NSItemProvider {
        let provider = NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL)
        provider.suggestedName = name
        return provider
    }
}

// MARK: - Icons

/// A file's Finder icon straight away, replaced by its Quick Look thumbnail (the
/// picture in an image, the first page of a document) once one has been made.
struct FileIcon: View {
    let url: URL
    let size: CGFloat
    @State private var thumbnail: NSImage?

    init(url: URL, size: CGFloat) {
        self.url = url
        self.size = size
        _thumbnail = State(initialValue: FileThumbnails.shared.cachedThumbnail(for: url, size: size))
    }

    var body: some View {
        Image(nsImage: thumbnail ?? FileThumbnails.shared.icon(for: url))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .task(id: url) {
                thumbnail = await FileThumbnails.shared.thumbnail(for: url, size: size)
            }
    }
}

/// Finder icons and Quick Look thumbnails for shelf items, kept so that reopening
/// the island does not make them again. Quick Look draws out of process; only the
/// cache lives on the main actor.
@MainActor
final class FileThumbnails {
    static let shared = FileThumbnails()

    private let icons = NSCache<NSString, NSImage>()
    private let thumbnails = NSCache<NSString, NSImage>()
    /// Files Quick Look has no thumbnail for (folders, apps), so it is not asked again.
    private var noThumbnail: Set<String> = []

    private init() {}

    func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let icon = icons.object(forKey: key) { return icon }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons.setObject(icon, forKey: key)
        return icon
    }

    func cachedThumbnail(for url: URL, size: CGFloat) -> NSImage? {
        thumbnails.object(forKey: Self.key(url, size) as NSString)
    }

    func thumbnail(for url: URL, size: CGFloat) async -> NSImage? {
        let key = Self.key(url, size)
        if let cached = thumbnails.object(forKey: key as NSString) { return cached }
        guard !noThumbnail.contains(key) else { return nil }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size, height: size),
            scale: NSScreen.screens.map(\.backingScaleFactor).max() ?? 2,
            representationTypes: [.lowQualityThumbnail, .thumbnail]
        )
        // Framed like Finder draws it: a page edge on documents, a border on photos.
        request.iconMode = true
        guard let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        else {
            noThumbnail.insert(key)
            return nil
        }
        thumbnails.setObject(image, forKey: key as NSString)
        return image
    }

    /// Lets the images go when the feature stops.
    func removeAll() {
        icons.removeAllObjects()
        thumbnails.removeAllObjects()
        noThumbnail.removeAll()
    }

    private static func key(_ url: URL, _ size: CGFloat) -> String {
        "\(url.path)#\(Int(size))"
    }
}
