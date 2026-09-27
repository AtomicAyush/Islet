import AppKit

/// A file as a drag carries it out of the island: the file itself, under its own name,
/// so Finder copies it, a mail becomes an attachment and an upload field takes it.
enum FileDrag {
    static func provider(for url: URL) -> NSItemProvider {
        let provider = NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL)
        provider.suggestedName = url.lastPathComponent
        return provider
    }
}
