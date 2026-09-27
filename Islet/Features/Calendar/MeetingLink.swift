import AppKit

/// A link that joins an online meeting, found in an event's URL, location or notes.
struct MeetingLink: Equatable, Sendable {
    enum Service: Equatable, Sendable {
        case zoom, meet, teams, webex, faceTime, slack
        /// A host that is plainly for meetings but has no app here to hand its link
        /// to, by the name it goes by: Jitsi Meet, Whereby.
        case other(String)

        var name: String {
            switch self {
            case .zoom: "Zoom"
            case .meet: "Google Meet"
            case .teams: "Microsoft Teams"
            case .webex: "Webex"
            case .faceTime: "FaceTime"
            case .slack: "Slack huddle"
            case .other(let name): name
            }
        }
    }

    let service: Service
    /// The link as found, out of any mail scanner's or search engine's redirect, and
    /// on https where it is a web link.
    let url: URL

    /// Recognises a join link by host and path, looking through a redirect first. Anything
    /// else (a meeting's web page, a Zoom sign-in link, a Teams chat, a shared document)
    /// is not something to join.
    init?(url found: URL) {
        let url = Self.unwrapped(found)
        guard let scheme = url.scheme?.lowercased() else { return nil }
        let path = url.path()

        switch scheme {
        case "zoommtg", "zoomus":
            // Zoom's own link is written again to join and do nothing more: as found, it
            // could as well start the meeting as its host, or carry anything else Zoom
            // takes.
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard path == "/join", let number = items.first(where: { $0.name == "confno" })?.value,
                  let join = Self.zoomJoin(host: url.host(), number: number, items: items)
            else { return nil }
            self.init(service: .zoom, url: join)
        case "msteams":
            guard Self.isTeamsMeeting(path) else { return nil }
            self.init(service: .teams, url: url)
        case "http", "https":
            guard let host = url.host()?.lowercased(), let (service, written) = Self.service(host: host, path: path)
            else { return nil }
            // Links typed without a scheme are detected as http; every service here is https.
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            components?.host = host
            components?.percentEncodedPath = written
            self.init(service: service, url: components?.url ?? url)
        default:
            return nil
        }
    }

    private init(service: Service, url: URL) {
        self.service = service
        self.url = url
    }

    /// The service a web link joins, with its path as the service writes it: a link
    /// typed by hand can have its letters in the wrong case.
    private static func service(host: String, path: String) -> (Service, path: String)? {
        func isHost(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        let lowered = path.lowercased()

        if isZoomHost(host) {
            guard let kind = ["/j/", "/my/", "/w/", "/wc/"].first(where: lowered.hasPrefix) else { return nil }
            return (.zoom, kind + path.dropFirst(kind.count))
        }
        if host == "meet.google.com" {
            // A meeting's code, with its dashes or without, or a nickname looked up.
            if lowered.wholeMatch(of: #//([a-z]{3}-[a-z]{4}-[a-z]{3}|[a-z]{10})/?/#) != nil { return (.meet, lowered) }
            return path.hasPrefix("/lookup/") ? (.meet, path) : nil
        }
        if host == "g.co" {
            return path.hasPrefix("/meet/") ? (.meet, path) : nil
        }
        if teamsHosts.contains(host) {
            return isTeamsMeeting(path) ? (.teams, path) : nil
        }
        if host.hasSuffix(".webex.com") {
            // A meeting's page, a person's room, or an event's (`e.php`, and the older
            // `onstage/g.php`).
            let joins = ["/j.php", "/e.php", "/onstage/g.php"].contains(where: lowered.hasSuffix)
                || lowered.hasPrefix("/meet/") || lowered.hasPrefix("/join/") || lowered.contains("/joinservice/")
                || (lowered.hasPrefix("/webappng/sites/") && lowered.contains("/meeting/"))
            return joins ? (.webex, path) : nil
        }
        if host == "facetime.apple.com" {
            return path.hasPrefix("/join") ? (.faceTime, path) : nil
        }
        if isHost("slack.com") {
            return path.hasPrefix("/huddle/") ? (.slack, path) : nil
        }
        return otherService(host: host, path: path).map { ($0, path) }
    }

    private static func isZoomHost(_ host: String) -> Bool {
        ["zoom.us", "zoomgov.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Zoom's meeting numbers are digits, and only the ten everyone writes: a number in
    /// another script would make a link Zoom can't read.
    private static func isMeetingNumber(_ number: some StringProtocol) -> Bool {
        !number.isEmpty && number.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static let teamsHosts: Set<String> = [
        "teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft",
        "gov.teams.microsoft.us", "dod.teams.microsoft.us",
    ]

    private static func isTeamsMeeting(_ path: String) -> Bool {
        path.hasPrefix("/l/meetup-join/") || path.hasPrefix("/meet/")
    }

    /// Hosts that are there only for meetings, by the name each goes by, for a link to
    /// one of its rooms. The rest of such a site (its home page, pricing, the app to
    /// install) is not somewhere to join.
    private static func otherService(host: String, path: String) -> Service? {
        if host == "whereby.com" || host.hasSuffix(".whereby.com") {
            return isRoomName(path) ? .other("Whereby") : nil
        }
        return switch host {
        case "meet.jit.si":
            isRoomName(path) ? .other("Jitsi Meet") : nil
        case "meet.goto.com":
            path.wholeMatch(of: #//\d{9,}/?/#) != nil ? .other("GoTo Meeting") : nil
        case "global.gotomeeting.com":
            path.wholeMatch(of: #//join/\d{9,}/?/#) != nil ? .other("GoTo Meeting") : nil
        case "v.ringcentral.com":
            path.wholeMatch(of: #//join/\d+/?/#) != nil ? .other("RingCentral") : nil
        default:
            nil
        }
    }

    /// A room's name, the one word after the host that Jitsi and Whereby give a room
    /// (`/islet-team`), and not one of the site's own pages.
    private static func isRoomName(_ path: String) -> Bool {
        guard let name = path.wholeMatch(of: #//([A-Za-z0-9][A-Za-z0-9_%-]*)/?/#)?.output.1 else { return false }
        return !sitePages.contains(name.lowercased())
    }

    private static let sitePages: Set<String> = [
        "about", "api", "blog", "download", "downloads", "embed", "help", "information", "install", "legal",
        "login", "org", "pricing", "privacy", "signup", "static", "support", "terms", "user",
    ]

    // MARK: Finding

    /// The first join link, trying the event's own URL before the text fields in order.
    /// A link to one of the services with a name of its own comes before one to a host
    /// that is only known to be for meetings, wherever the two are found.
    static func find(url: URL?, in texts: [String?], detector: NSDataDetector?) -> MeetingLink? {
        var fallback: MeetingLink?
        let found = [url].compactMap { $0 } + texts.compactMap { $0 }.flatMap { links(in: $0, detector: detector) }
        for candidate in found {
            guard let link = MeetingLink(url: candidate) else { continue }
            if case .other = link.service {
                fallback = fallback ?? link
            } else {
                return link
            }
        }
        return fallback
    }

    /// Every link in the text, in the order they come. The detector finds web links
    /// with or without their scheme, and Zoom's own; Teams' own, which has no `//`
    /// after its scheme, it passes over. Those are taken up to the next space or
    /// bracket, less the full stop or comma of a sentence that ends with one.
    private static func links(in text: String, detector: NSDataDetector?) -> [URL] {
        guard !text.isEmpty else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var found: [(location: Int, url: URL)] = []
        for match in detector?.matches(in: text, range: range) ?? [] {
            if let url = match.url { found.append((match.range.location, url)) }
        }
        for match in text.matches(of: #/msteams:/[^\s<>"'()\[\]]+/#) {
            var link = match.output
            while let last = link.last, ".,;:!?".contains(last) { link = link.dropLast() }
            if let url = URL(string: String(link)) {
                found.append((NSRange(match.range, in: text).location, url))
            }
        }
        return found.sorted { $0.location < $1.location }.map(\.url)
    }

    // MARK: Redirects

    /// The link inside a redirect: Outlook's Safe Links and Proofpoint, which wrap every
    /// link in a mail they scan, Google's, which wraps the links in an invitation's
    /// notes, and Teams' own launcher page. A redirect can wrap another, so a few layers
    /// are taken off.
    static func unwrapped(_ url: URL) -> URL {
        var current = url
        for _ in 0..<4 {
            guard let inner = wrapped(in: current) else { break }
            current = inner
        }
        return current
    }

    private static func wrapped(in url: URL) -> URL? {
        guard let host = url.host()?.lowercased(),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let path = url.path()
        func item(_ name: String) -> String? {
            components.queryItems?.first { $0.name == name }?.value
        }

        let target: String?
        if host.hasSuffix(".safelinks.protection.outlook.com") || host.hasSuffix(".safelinks.protection.office365.us")
            || (host == "statics.teams.cdn.office.net" && path.contains("/safelinks/")) {
            target = item("url")
        } else if (host == "google.com" || host.hasPrefix("www.google.") || host.hasPrefix("google.")), path == "/url" {
            target = item("q") ?? item("url")
        } else if host == "urldefense.com", path.hasPrefix("/v3/__") {
            target = proofpointV3(url.absoluteString)
        } else if host == "urldefense.proofpoint.com", path.hasPrefix("/v2/url") {
            target = item("u").flatMap(proofpointV2)
        } else if teamsHosts.contains(host), path == "/dl/launcher/launcher.html" {
            // Teams' launcher, with the meeting's path on this host in its `url`.
            target = item("url").map { $0.hasPrefix("/") ? "https://\(host)\($0)" : $0 }
        } else if teamsHosts.contains(host), path == "/_", let fragment = url.fragment(percentEncoded: true),
                  fragment.hasPrefix("/l/") {
            // The older Teams web app's links, `/_#/l/meetup-join/…`, with the path after the `#`.
            target = "https://\(host)\(fragment)"
        } else {
            target = nil
        }
        guard let target, let inner = URL(string: target), inner.scheme != nil else { return nil }
        return inner
    }

    /// `https://urldefense.com/v3/__https://example.com/a?b=c__;!!…`: the link sits
    /// between the underscores as it was, but for characters Proofpoint swaps for `*`
    /// and lists after them, which are left alone rather than guessed at.
    private static func proofpointV3(_ string: String) -> String? {
        guard let start = string.range(of: "/v3/__"),
              let end = string.range(of: "__;", range: start.upperBound..<string.endIndex)
        else { return nil }
        let inner = String(string[start.upperBound..<end.lowerBound])
        return inner.contains("*") ? nil : inner
    }

    /// `u=https-3A__example.com_a-3Fb-3Dc`: `/` written as `_`, and everything else
    /// that needs escaping as `-` and two hex digits.
    private static func proofpointV2(_ encoded: String) -> String? {
        let slashes = encoded.replacingOccurrences(of: "_", with: "/")
        return slashes.replacing(#/-([0-9A-Fa-f]{2})/#) { "%" + $0.output.1 }.removingPercentEncoding
    }

    // MARK: Opening

    /// The meeting in the service's own app, where it has a link of its own for one:
    /// Zoom's `zoommtg:`, Teams' `msteams:`. Their web pages would only hand the
    /// meeting on to the app, after a detour through the browser.
    var appURL: URL? {
        switch service {
        case .zoom:
            // Zoom's own links were written as a join when found.
            if url.scheme?.lowercased() != "https" { return url }
            let parts = url.pathComponents
            guard parts.count >= 3, parts[1] == "j" || parts[1] == "w" else { return nil }
            let passed = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return Self.zoomJoin(host: url.host(), number: parts[2], items: passed)
        case .teams:
            if url.scheme?.lowercased() == "msteams" { return url }
            // Only the meeting links Teams' own launcher hands to the app. The shorter
            // `/meet/` ones, personal Teams and the newer hosts are left to their web
            // pages, which know which app, if any, takes them.
            guard url.host()?.lowercased() == "teams.microsoft.com", url.path().hasPrefix("/l/meetup-join/"),
                  var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else { return nil }
            components.scheme = "msteams"
            components.host = nil
            return components.url
        default:
            return nil
        }
    }

    /// The meeting's web page, for the browser to open, or to hand to the app.
    var webURL: URL? {
        switch url.scheme?.lowercased() {
        case "https":
            return url
        case "msteams":
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            components?.host = "teams.microsoft.com"
            return components?.url
        case "zoommtg", "zoomus":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let number = items.first(where: { $0.name == "confno" })?.value, Self.isMeetingNumber(number)
            else { return nil }
            var components = URLComponents()
            components.scheme = "https"
            components.host = url.host() ?? "zoom.us"
            components.path = "/j/\(number)"
            let kept = items.filter { ["pwd", "tk"].contains($0.name) }
            components.queryItems = kept.isEmpty ? nil : kept
            return components.url
        default:
            return nil
        }
    }

    /// `zoommtg://<host>/join?action=join&confno=…`, with the passcode and a webinar's
    /// token and nothing else. A host that is not Zoom's is taken for zoom.us.
    private static func zoomJoin(host: String?, number: String, items: [URLQueryItem]) -> URL? {
        guard isMeetingNumber(number) else { return nil }
        var components = URLComponents()
        components.scheme = "zoommtg"
        components.host = host.map { $0.lowercased() }.flatMap { isZoomHost($0) ? $0 : nil } ?? "zoom.us"
        components.path = "/join"
        components.queryItems = [URLQueryItem(name: "action", value: "join"), URLQueryItem(name: "confno", value: number)]
            + items.filter { ["pwd", "tk"].contains($0.name) }
        return components.url
    }

    /// What to open: the app's own link where an app on this Mac takes it, else the
    /// web page.
    func launchURL(hasApp: (URL) -> Bool) -> URL {
        if let app = appURL, hasApp(app) { return app }
        return webURL ?? appURL ?? url
    }
}

/// Opens meeting links. Tests hand in one of their own, which only writes down what it
/// would have opened.
@MainActor
protocol MeetingOpener {
    /// Whether an app on this Mac opens links like `url`: for a `zoommtg:` one, whether
    /// Zoom is installed.
    func hasApp(for url: URL) -> Bool
    func open(_ url: URL)
}

struct WorkspaceMeetingOpener: MeetingOpener {
    func hasApp(for url: URL) -> Bool {
        NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
